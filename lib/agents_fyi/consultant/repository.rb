# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "timeout"

require_relative "errors"
require_relative "validator"

module AgentsFyi
  module Consultant
    # **A read-only mirror of the project, in the consultant's own volume.**
    #
    # The service cannot see a repository and the walker's tree is one loop's state with a torn-read
    # window, so a repo-aware answer has to come from a mirror this container makes itself. The
    # mirror is per repository (not per task), a shallow clone at the project's default branch, and
    # every read is `git show <ref>:<path>` — blobs, never a checkout, so a symlink in the repository
    # cannot lead this process outside it.
    #
    # **v1 is public-clone only.** There is no GitHub App token in this container: a private
    # repository is a `cannot` with a question for a person, not a credential widening. The files
    # are read for the prompt and nothing is written back.
    #
    # What the model sees is bounded twice: at most `MAX_FILES` files and `MAX_BYTES` of text, and
    # the runner's prompt clamp on top. A file whose text looks like it holds a secret is skipped
    # and named in the prompt as skipped rather than pasted in; the service would redact it on the
    # way back, but a credential never has to leave this process at all.
    class Repository
      MAX_FILES = 60
      MAX_BYTES = 64 * 1024
      MAX_FILE_BYTES = 48 * 1024
      COMMAND_TIMEOUT = 180
      CODE_EXTENSIONS = %w[.rb .rake .erb .jbuilder .ru .gemspec].freeze
      # **What a profile may quote, and what it may not edit.** CI, deploy and convention files are
      # read-only evidence for a profile proposal; the validator's effect denylist still refuses a
      # change to any of them.
      PROFILE_FILES = %w[Gemfile Gemfile.lock .ruby-version Rakefile Procfile .rspec
        config/application.rb config/boot.rb config/environment.rb Makefile bin/ci script/ci
        Dockerfile fly.toml render.yaml .rubocop.yml .standard.yml package.json .gitlab-ci.yml
        .circleci/config.yml].freeze
      PROFILE_PREFIXES = %w[.github/workflows/ k8s/].freeze
      SKIP_PREFIXES = %w[test/ spec/ features/ __tests__/ .github/ .circleci/ vendor/
        node_modules/ tmp/ log/ db/ .git/ config/credentials/ config/initializers/].freeze
      SKIP_BASENAMES = %w[.env .env.local .env.production .env.development .env.test
        config/credentials.yml.enc config/master.key config/database.yml config/secrets.yml
        config/storage.yml].freeze

      attr_reader :repo_url, :branch, :mirror, :skipped

      def initialize(config:, task:, out: nil, err: nil)
        @config = config
        @task = task
        project = task["project"].is_a?(Hash) ? task["project"] : {}
        @repo_url = project["repo_url"].to_s
        @branch = project["default_branch"].to_s
        @mirror = config.home.join("repos", Digest::SHA256.hexdigest(@repo_url))
        @out = out
        @err = err
        @skipped = []
      end

      def available? = !repo_url.empty?

      # `[snapshot, nil]` or `[nil, problem]`. A copy failure is a fact about the deployment (a
      # private repository, a network that is not there), not about the model, so it becomes a task
      # that needs a person rather than a retry loop.
      def snapshot(mode: "answer", question: {})
        return [nil, "the task names no repository"] unless available?

        problem = sync!
        return [nil, problem] if problem

        wanted = mode == "profile" ? profile_paths : code_paths(question)
        files = []
        bytes = 0
        wanted.each do |path|
          next if files.length >= MAX_FILES || bytes >= MAX_BYTES

          text = read(path)
          next if text.nil?
          next if text.bytesize > MAX_FILE_BYTES
          if Validator.secret?(text)
            skipped << { "path" => path, "reason" => "a value in it looks like a secret" }
            next
          end
          if bytes + text.bytesize > MAX_BYTES
            skipped << { "path" => path, "reason" => "the prompt's file budget was reached" }
            next
          end

          files << { "path" => path, "text" => text }
          bytes += text.bytesize
        end
        remaining = wanted.length - files.length - skipped.length
        skipped << { "path" => "#{remaining} more", "reason" => "the prompt's file budget was reached" } if
          remaining.positive?

        [{ "repo_url" => repo_url, "branch" => branch, "files" => files,
           "skipped" => skipped, "bytes" => bytes }, nil]
      end

      private

      def sync!
        @paths = nil
        if File.directory?(File.join(mirror, ".git"))
          fetch
        else
          clone
        end
      end

      def clone
        FileUtils.mkdir_p(mirror.dirname)
        argv = ["git", "clone", "--depth", "1", "--quiet"]
        argv += ["--branch", branch] unless branch.empty?
        # `--` stops a repository URL that begins with `-` from being read as an option.
        argv += ["--", repo_url, mirror.to_s]
        run(argv)
      end

      def fetch
        argv = ["git", "-C", mirror.to_s, "fetch", "--depth", "1", "--quiet", "origin"]
        argv << branch unless branch.empty?
        problem = run(argv)
        return problem if problem

        run(["git", "-C", mirror.to_s, "reset", "--hard", "--quiet", "FETCH_HEAD"])
      end

      # **A timeout is the whole command, and the child is killed.** A git clone that never returns
      # must not hold the task lease until the next consultant claims it. No shell: the URL and the
      # branch are arguments, never a command line.
      def run(argv)
        # The callers build the argv the way a person types it (`git clone …`); the helper adds
        # the executable, so the leading word is dropped rather than run twice.
        args = argv.first == "git" ? argv.drop(1) : argv
        _out, err, status = git(*args)
        return "git did not finish reading the repository within #{COMMAND_TIMEOUT}s" if
          status == :timeout
        return "git could not read the repository: #{err.to_s.lines.last.to_s.strip}" unless
          status.respond_to?(:success?) && status.success?

        nil
      rescue Errno::ENOENT
        "git is not installed in this container"
      rescue SystemCallError => e
        "git could not start: #{e.message}"
      end

      # `[stdout, stderr, status]`; status is `:timeout` when the deadline was spent and the child
      # was killed. The child is in its own process group, so TERM reaches git's own helpers too.
      def git(*argv)
        env = @config.env.slice("HOME", "PATH", "LANG", "LC_ALL", "XDG_CONFIG_HOME")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        Open3.popen3(env, "git", *argv, chdir: @config.home.to_s, pgroup: true) do |stdin, stdout, stderr, wait|
          stdin.close
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }
          unless wait.join(COMMAND_TIMEOUT)
            terminate(wait.pid)
            return [out.value, err.value, :timeout]
          end

          [out.value, err.value, wait.value]
        end
      end

      def terminate(pid)
        Process.kill("TERM", -pid)
        sleep 2
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end

      def paths
        @paths ||= begin
          out, _err, status = git("-C", mirror.to_s, "ls-tree", "-r", "--name-only", "HEAD")
          status.respond_to?(:success?) && status.success? ?
            out.lines.map(&:strip).reject(&:empty?) : []
        end
      end

      def profile_paths
        listed = paths
        exact = PROFILE_FILES.select { |path| listed.include?(path) }
        globbed = listed.select do |path|
          PROFILE_PREFIXES.any? { |prefix| path.start_with?(prefix) } &&
            %w[.yml .yaml].include?(File.extname(path))
        end
        (exact + globbed).uniq
      end

      # The question's own file first, then the code the move touches. Tests, CI, dependencies and
      # generated output are not read: a profile fact is not in `spec/`, and a repair's evidence is
      # the file the failure names.
      def code_paths(question)
        listed = paths.reject { |path| skip?(path) }
        context = question["context"].is_a?(Hash) ? question["context"] : {}
        evidence = question["evidence"].is_a?(Hash) ? question["evidence"] : {}
        named = [context["file"], evidence["file"], question["subject"]].filter_map do |value|
          text = value.to_s
          text = text.split(":").first if text.include?(":")
          text if text != "" && listed.include?(text)
        end
        (named + listed.select { |path| code?(path) }).uniq
      end

      def skip?(path)
        SKIP_PREFIXES.any? { |prefix| path.start_with?(prefix) } ||
          SKIP_BASENAMES.include?(path)
      end

      def code?(path)
        CODE_EXTENSIONS.include?(File.extname(path)) &&
          path.match?(%r{\A(app|lib|config|engines|packages)/})
      end

      def read(path)
        out, _err, status = git("-C", mirror.to_s, "show", "HEAD:#{path}")
        status.respond_to?(:success?) && status.success? ? out : nil
      end
    end
  end
end
