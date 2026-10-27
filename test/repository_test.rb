# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

require "agents/consultant"

class RepositoryTest < Minitest::Test
  def git(dir, *argv)
    env = { "GIT_CONFIG_NOSYSTEM" => "1", "HOME" => dir,
            "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.test",
            "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.test" }
    out, err, status = Open3.capture3(env, "git", "-C", dir, *argv)
    raise "git #{argv.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def repo(dir)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    FileUtils.mkdir_p(File.join(dir, "test"))
    File.write(File.join(dir, "app", "models", "user.rb"), "class User\n  before_filter :x\nend\n")
    File.write(File.join(dir, "test", "user_test.rb"), "class UserTest < Minitest::Test\nend\n")
    File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    minitest (5.25.0)\n")
    File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n  NewCops: enable\n")
    FileUtils.mkdir_p(File.join(dir, ".github", "workflows"))
    File.write(File.join(dir, ".github", "workflows", "ci.yml"),
      "jobs:\n  test:\n    steps:\n      - run: bundle exec rspec\n")
    git(dir, "init", "-q", "-b", "main")
    git(dir, "add", ".")
    git(dir, "commit", "-q", "-m", "initial")
    dir
  end

  def config(home)
    Agents::Consultant::Config.new(
      base_url: "http://service:8001", key: "afy_x", model: "test/model",
      interval: 0, claim_limit: 1, kinds: %w[scan], task_timeout: 60,
      opencode_binary: "true", agent: "consultant", home: home
    )
  end

  def task(repo_path)
    { "id" => "task-1", "project" => { "repo_url" => repo_path, "default_branch" => "main" } }
  end

  def test_a_mirror_reads_the_named_file_and_skips_the_test_tree
    Dir.mktmpdir do |root|
      source = repo(File.join(root, "source"))
      home = File.join(root, "home")
      repository = Agents::Consultant::Repository.new(config: config(home),
        task: task(source))

      snapshot, problem = repository.snapshot(mode: "scan",
        question: { "context" => { "file" => "app/models/user.rb" } })

      assert_nil problem
      assert_equal ["app/models/user.rb"], snapshot["files"].map { |file| file["path"] }
      assert_includes snapshot["files"].first["text"], "before_filter"
      assert(File.directory?(File.join(home, "repos")))
    end
  end

  def test_the_profile_read_takes_the_lockfile_and_not_the_test_tree
    Dir.mktmpdir do |root|
      source = repo(File.join(root, "source"))
      repository = Agents::Consultant::Repository.new(config: config(File.join(root, "home")),
        task: task(source))

      snapshot, problem = repository.snapshot(mode: "profile")

      assert_nil problem
      assert_equal ["Gemfile.lock", ".rubocop.yml", ".github/workflows/ci.yml"],
        snapshot["files"].map { |file| file["path"] },
        "the profile reads the company's CI and convention files read-only"
    end
  end

  def test_a_secret_looking_file_is_skipped_and_named
    Dir.mktmpdir do |root|
      source = repo(File.join(root, "source"))
      File.write(File.join(source, "app", "models", "secret.rb"),
        "API_KEY = \"afy_canary_12345678\"\n")
      git(source, "add", ".")
      git(source, "commit", "-q", "-m", "secret")
      repository = Agents::Consultant::Repository.new(config: config(File.join(root, "home")),
        task: task(source))

      snapshot, problem = repository.snapshot(mode: "scan", question: {})

      assert_nil problem
      refute_includes snapshot["files"].map { |file| file["path"] }, "app/models/secret.rb"
      assert(snapshot["skipped"].any? { |row| row["path"] == "app/models/secret.rb" })
    end
  end

  def test_an_unreadable_repository_is_a_sentence_not_a_crash
    Dir.mktmpdir do |root|
      repository = Agents::Consultant::Repository.new(config: config(File.join(root, "home")),
        task: task(File.join(root, "does-not-exist")))

      snapshot, problem = repository.snapshot(mode: "profile")

      assert_nil snapshot
      assert_match(/could not read the repository/, problem)
    end
  end

  def test_a_second_snapshot_sees_a_new_commit
    Dir.mktmpdir do |root|
      source = repo(File.join(root, "source"))
      repository = Agents::Consultant::Repository.new(config: config(File.join(root, "home")),
        task: task(source))
      repository.snapshot(mode: "scan", question: {})

      File.write(File.join(source, "app", "models", "post.rb"), "class Post\nend\n")
      git(source, "add", ".")
      git(source, "commit", "-q", "-m", "post")

      snapshot, problem = repository.snapshot(mode: "scan", question: {})
      assert_nil problem
      assert_includes snapshot["files"].map { |file| file["path"] }, "app/models/post.rb"
    end
  end
end
