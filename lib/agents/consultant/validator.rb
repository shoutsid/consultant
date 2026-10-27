# frozen_string_literal: true

require "json"
require "digest"

module Agents
  module Consultant
    # **The model's output is data, and this is where it stops being trusted.**
    #
    # The service classifies risk and validates effects again; this is the client-side gate that
    # keeps an obviously unsafe proposal out of a request at all. It refuses a test, CI, secret,
    # dependency, boot, database or deploy path, a whole-file effect, an unknown kind, a malformed
    # find, a secret-looking value and an answer with no effects. A refusal is not a crash: the loop
    # posts it as `cannot` with a need, so a person sees why the consultant stopped.
    module Validator
      KINDS = %w[patch config gem file delete chmod rule].freeze
      RULE_KINDS = %w[rewrite insert config patch].freeze
      FORBIDDEN_PREFIXES = %w[test/ spec/ features/ .github/ .circleci/ bin/ script/
        config/credentials config/initializers/ config/environments/ vendor/ .git/].freeze
      FORBIDDEN_BASENAMES = %w[Gemfile Gemfile.lock package.json package-lock.json yarn.lock
        Dockerfile docker-compose.yml Procfile Rakefile .env .env.local .env.production
        config/application.rb config/boot.rb config/environment.rb db/schema.rb db/structure.sql].freeze
      FORBIDDEN_EXTENSIONS = %w[.pem .key .p12 .pfx].freeze
      MAX_EFFECTS = 20
      MAX_BYTES = 48 * 1024
      REVIEW_VERDICTS = %w[safe unsafe needs].freeze
      REVIEW_CONCERN_KINDS = %w[masked_failure weakened_test widened_change wrong_effect
        insufficient_evidence].freeze
      REVIEW_EVIDENCE_KINDS = %w[file output run profile].freeze
      REVIEW_ITEMS = 20
      PRESENT_ANCHOR = /\A(path|commit|decision|check|report|change):\S.*\z/
      PRESENT_MIN_SUMMARY = 40
      PRESENT_MAX_SUMMARY = 1_200
      PRESENT_MAX_FOCUS = 5
      PRESENT_MIN_WHY = 20
      PRESENT_MAX_WHY = 300
      PRESENT_MIN_NARRATIVE = 80
      PRESENT_MAX_NARRATIVE = 1_800
      PRESENT_MAX_NARRATIVE_TOTAL = 3_200
      PRESENT_NARRATIVE_KEYS = %w[what_moved what_changed].freeze

      class Refusal < StandardError; end

      class << self
        # `[proposal, nil]` or `[nil, sentence]`. A non-answer carries no effects by contract.
        def read(text, mode: "answer")
          parsed = parse(text)
          stance = parsed["stance"].to_s
          stance = "answer" if stance.empty?
          unless %w[answer maybe cannot].include?(stance)
            return [nil, "stance is answer, maybe or cannot; got #{stance.inspect}"]
          end

          choice = parsed["choice"].to_s.strip
          choice = stance if choice.empty?
          effects = Array(parsed["effects"]).grep(Hash)
          effects = [] if stance != "answer"
          if stance == "answer" && effects.empty?
            return [nil, "an answer needs at least one typed effect; use maybe or cannot instead"]
          end
          if effects.length > MAX_EFFECTS
            return [nil, "the proposal carries #{effects.length} effects; the bound is #{MAX_EFFECTS}"]
          end

          checked = effects.each_with_index.map do |effect, index|
            result, problem = check_effect(effect, index)
            return [nil, problem] if problem

            result
          end
          # **A repair is applied after `app:update`, not before the baseline.** The service
          # refuses a `pre` repair by policy and the walker has a post pass; this is the client's
          # half of the same rule.
          checked = checked.map { |effect| effect.merge("phase" => "post") } if mode == "repair"
          if checked.to_json.bytesize > MAX_BYTES
            return [nil, "the proposal's effects exceed #{MAX_BYTES} bytes"]
          end

          needs = read_needs(parsed["needs"])
          return [nil, needs] if needs.is_a?(String)

          provenance = parsed["provenance"].is_a?(Hash) ? parsed["provenance"] : {}
          if stance != "cannot" && provenance.empty?
            return [nil, "a model proposal needs provenance (model, harness, prompt_version)"]
          end

          [{
            "stance" => stance,
            "choice" => choice[0, 120],
            "rationale" => parsed["rationale"].to_s[0, 8 * 1024],
            "effects" => checked,
            "needs" => needs,
            "profile" => parsed["profile"].is_a?(Hash) ? parsed["profile"] : {},
            "evidence" => Array(parsed["evidence"]).grep(Hash).first(50),
            "provenance" => provenance.merge("harness" => "consultant/1"),
            "mode" => mode
          }, nil]
        rescue Refusal => e
          [nil, e.message]
        end

        # A profile proposal is a field map, not an effect list. The service classifies each
        # field; this refuses the fields a model must never suggest and a secret in any value.
        # **A scan annotation is not an effect.** It says the deterministic scan missed a call
        # site, reported a false positive, or found a change with no call site. A suggested effect
        # inside one is validated by the same gate as an answer, so a test-path or whole-file
        # suggestion cannot ride along; the annotation itself applies nothing.
        def read_scan(text)
          parsed = parse(text)
          stance = parsed["stance"].to_s
          provenance = parsed["provenance"].is_a?(Hash) ? parsed["provenance"] : {}
          if %w[maybe cannot].include?(stance)
            return [nil, "a scan answer needs provenance (model, harness, prompt_version)"] if
              provenance.empty?
            needs = read_needs(parsed["needs"])
            return [nil, needs] if needs.is_a?(String)

            return [{ "stance" => stance, "annotations" => [], "needs" => needs,
                      "rationale" => parsed["rationale"].to_s[0, 8 * 1024],
                      "provenance" => provenance.merge("harness" => "consultant/1") }, nil]
          end

          raw = parsed["annotations"]
          return [nil, "a scan answer needs an `annotations` list"] unless raw.is_a?(Array)
          return [nil, "a scan carries at most 50 annotations"] if raw.length > 50

          annotations = raw.each_with_index.map do |item, index|
            raise Refusal, "annotation #{index} is not an object" unless item.is_a?(Hash)

            kind = item["kind"].to_s
            unless %w[missed false_positive not_present].include?(kind)
              raise Refusal, "annotation #{index} is missed, false_positive or not_present; " \
                             "got #{kind.inspect}"
            end
            effects = Array(item["effects"]).grep(Hash).each_with_index.map do |effect, position|
              result, problem = check_effect(effect, position)
              raise Refusal, "annotation #{index}: #{problem}" if problem

              result
            end
            {
              "kind" => kind,
              "path" => item["path"].to_s[0, 500],
              "line" => item["line"].to_i.positive? ? item["line"].to_i : nil,
              "subject" => item["subject"].to_s[0, 200],
              "detail" => item["detail"].to_s[0, 4 * 1024],
              "effects" => effects
            }.compact
          end

          return [nil, "a scan answer needs provenance (model, harness, prompt_version)"] if
            provenance.empty?
          if annotations.to_json.bytesize > 24 * 1024
            return [nil, "the annotations exceed 24 KiB; keep the highest-value ones"]
          end

          [{ "stance" => "answer", "annotations" => annotations,
             "rationale" => parsed["rationale"].to_s[0, 8 * 1024],
             "provenance" => provenance.merge("harness" => "consultant/1") }, nil]
        rescue Refusal => e
          [nil, e.message]
        end

        def read_profile(text)
          parsed = parse(text)
          fields = parsed["fields"].is_a?(Hash) ? parsed["fields"] : {}
          return [nil, "a profile answer needs a `fields` object"] if fields.empty?
          return [nil, "the profile proposes more than 20 fields"] if fields.length > 20

          cleaned = {}
          fields.each do |name, raw|
            key = name.to_s
            unless %w[from to suite services source_roots env_names toolchain style app_update
                      checks path_policy base_ref repo deploy conventions domain_notes].include?(key)
              return [nil, "profile field #{key.inspect} is not one the consultant may propose"]
            end

            value = raw.is_a?(Hash) ? raw["value"] : raw
            if secret?(value)
              return [nil, "profile field #{key} contains a value that looks like a secret"]
            end
            cleaned[key] = raw.is_a?(Hash) ? raw : { "value" => raw }
          end

          provenance = parsed["provenance"].is_a?(Hash) ? parsed["provenance"] : {}
          return [nil, "a profile proposal needs provenance"] if provenance.empty?

          [{
            "fields" => cleaned,
            "evidence" => parsed["evidence"].is_a?(Hash) ? parsed["evidence"] : {},
            "provenance" => provenance.merge("harness" => "consultant/1"),
            "rationale" => parsed["rationale"].to_s[0, 8 * 1024]
          }, nil]
        rescue Refusal => e
          [nil, e.message]
        end

        # **A review is a verdict, two small evidence lists and a provenance that names the
        # reviewer agent.** The service checks the same shape again; this is the client gate that
        # keeps a malformed or self-reviewing answer from being posted at all.
        def read_review(text)
          parsed = parse(text)
          verdict = parsed["verdict"].to_s
          unless REVIEW_VERDICTS.include?(verdict)
            return [nil, "verdict is safe, unsafe or needs; got #{verdict.inspect}"]
          end

          concerns, problem = review_items(parsed["concerns"], "concerns",
            REVIEW_CONCERN_KINDS)
          return [nil, problem] if problem

          evidence, problem = review_items(parsed["evidence"], "evidence",
            REVIEW_EVIDENCE_KINDS)
          return [nil, problem] if problem

          if verdict == "safe" && evidence.empty?
            return [nil, "a safe review names at least one evidence item it checked"]
          end

          provenance = parsed["provenance"].is_a?(Hash) ? parsed["provenance"] : {}
          return [nil, "a review needs provenance (model, agent, prompt_version, files_read)"] if
            provenance["model"].to_s.strip.empty? || provenance["agent"].to_s != "reviewer" ||
              provenance["prompt_version"].to_s.strip.empty? ||
              Array(provenance["files_read"]).empty?

          [{
            "verdict" => verdict,
            "concerns" => concerns,
            "evidence" => evidence,
            "rationale" => parsed["rationale"].to_s[0, 8 * 1024],
            "provenance" => provenance.merge("harness" => "consultant/1")
          }, nil]
        rescue Refusal => e
          [nil, e.message]
        end

        # **A presentation is prose with typed anchors, not a second review.** The service checks
        # that each anchor exists in the run's fact sheet; this gate keeps the shape, the length and
        # the secrets out of the request at all. The model is allowed to say `cannot` only by not
        # answering; a presentation task has one useful result, the lead.
        def read_presentation(text)
          parsed = parse(text)
          summary = parsed["summary"].to_s.strip
          if summary.length < PRESENT_MIN_SUMMARY || summary.length > PRESENT_MAX_SUMMARY
            return [nil, "the summary must be #{PRESENT_MIN_SUMMARY} to #{PRESENT_MAX_SUMMARY} characters"]
          end
          return [nil, "the summary carries raw HTML"] if summary.match?(/<\/?[A-Za-z][^>]*>/)
          return [nil, "the summary carries a heading"] if summary.match?(/^\s*#/m)
          return [nil, "the summary carries a code fence"] if summary.include?("```")
          return [nil, "the summary carries a Markdown link"] if summary.include?("](")
          return [nil, "the summary carries a secret-looking value"] if secret?(summary)

          focus = Array(parsed["review_focus"]).grep(Hash)
          if focus.empty? || focus.length > PRESENT_MAX_FOCUS
            return [nil, "review_focus must carry 1 to #{PRESENT_MAX_FOCUS} items"]
          end

          cleaned = focus.each_with_index.map do |item, index|
            anchor = item["anchor"].to_s.strip
            why = item["why"].to_s.strip
            unless PRESENT_ANCHOR.match?(anchor)
              return [nil, "review_focus #{index + 1} needs a typed anchor " \
                           "(path:, commit:, decision:, check:, report: or change:)"]
            end
            if why.length < PRESENT_MIN_WHY || why.length > PRESENT_MAX_WHY
              return [nil, "review_focus #{index + 1} needs a reason of #{PRESENT_MIN_WHY} to " \
                           "#{PRESENT_MAX_WHY} characters"]
            end
            return [nil, "review_focus #{index + 1} carries raw HTML"] if why.match?(/<\/?[A-Za-z][^>]*>/)
            return [nil, "review_focus #{index + 1} carries a code fence"] if why.include?("```")
            return [nil, "review_focus #{index + 1} carries a Markdown link"] if why.include?("](")
            return [nil, "review_focus #{index + 1} carries a secret-looking value"] if secret?(why)

            { "anchor" => anchor, "why" => why }
          end

          provenance = parsed["provenance"].is_a?(Hash) ? parsed["provenance"] : {}
          if provenance["model"].to_s.strip.empty? || provenance["prompt_version"].to_s.strip.empty?
            return [nil, "a presentation needs provenance (model, prompt_version)"]
          end

          narrative, narrative_problem = read_narrative(parsed["narrative"])
          return [nil, narrative_problem] if narrative_problem

          [{
            "summary" => summary,
            "review_focus" => cleaned,
            "narrative" => narrative,
            "provenance" => provenance.merge("harness" => "consultant/1")
          }, nil]
        rescue Refusal => e
          [nil, e.message]
        end

        # **The narratives are prose, and the service adds the headings.** This gate refuses a
        # heading, list, table, link or secret before the request is sent; the service checks the
        # claims, versions and anchors against the record. Both are required: a presenter that
        # answers without them answered the previous version of the task.
        def read_narrative(raw)
          return [nil, "a presentation needs what_moved and what_changed narratives"] unless
            raw.is_a?(Hash)

          cleaned = {}
          total = 0
          PRESENT_NARRATIVE_KEYS.each do |key|
            label = key.tr("_", " ")
            value = raw[key]
            return [nil, "the #{label} narrative must be text"] unless value.is_a?(String)

            text = value.gsub(/\r\n?/, "\n").strip
            if text.length < PRESENT_MIN_NARRATIVE || text.length > PRESENT_MAX_NARRATIVE
              return [nil, "the #{label} narrative must be #{PRESENT_MIN_NARRATIVE} to " \
                           "#{PRESENT_MAX_NARRATIVE} characters"]
            end
            return [nil, "the #{label} narrative carries raw HTML"] if
              text.match?(/<\/?[A-Za-z][^>]*>/)
            return [nil, "the #{label} narrative carries a heading"] if text.match?(/^\s*#/m)
            if text.match?(/^\s*(?:[-*+>]\s|\|\s?|\d+\.\s)/m)
              return [nil, "the #{label} narrative carries a list or a table; write prose paragraphs"]
            end
            return [nil, "the #{label} narrative carries a code span or fence; write prose " \
                         "without backticks"] if text.include?("`")
            return [nil, "the #{label} narrative carries a code fence"] if
              text.match?(/^\s{0,3}~{3,}/m)
            return [nil, "the #{label} narrative carries a Setext underline"] if
              text.match?(/^\s{0,3}(?:=+|-{2,})\s*$/m)
            return [nil, "the #{label} narrative carries a Markdown link"] if
              text.include?("](") || text.include?("][")
            return [nil, "the #{label} narrative carries a reference link"] if
              text.match?(/^\s{0,3}\[[^\]]+\]:/m)
            return [nil, "the #{label} narrative carries a typed anchor; it belongs in " \
                         "review_focus only"] if
              text.match?(/\b(?:path|commit|decision|check|report|change):/)
            return [nil, "the #{label} narrative carries a secret-looking value"] if secret?(text)

            cleaned[key] = text
            total += text.length
          end
          if total > PRESENT_MAX_NARRATIVE_TOTAL
            return [nil, "the narrative is longer than #{PRESENT_MAX_NARRATIVE_TOTAL} characters " \
                         "in total"]
          end

          [cleaned, nil]
        end

        def parse(text)
          body = text.to_s.strip
          body = body.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
          first = body.index("{")
          last = body.rindex("}")
          raise Refusal, "the model did not answer with a JSON object" if first.nil? || last.nil? ||
            last < first

          JSON.parse(body[first..last])
        rescue JSON::ParserError => e
          raise Refusal, "the model's JSON is malformed: #{e.message.to_s.lines.first.to_s.strip}"
        end

        def secret?(value)
          text = value.is_a?(String) ? value : value.to_json
          return true if text.match?(/-----BEGIN [A-Z ]*PRIVATE KEY-----/)
          return true if text.match?(/\bafy_[A-Za-z0-9_-]{8,}\b/)
          return true if text.match?(/\bgh[pousr]_[A-Za-z0-9]{20,}\b/)
          return true if text.match?(/\bsk-[A-Za-z0-9_-]{20,}\b/)
          return true if text.match?(%r{(postgres(?:ql)?://[^:/\s]+:)[^@\s]+@}i)
          return true if text.match?(/\b(SECRET_KEY_BASE|PASSWORD|PASSWD|API_KEY|ACCESS_TOKEN)\s*[:=]\s*["']?[A-Za-z0-9+\/=_-]{16,}/i)

          false
        end

        private

        def review_items(raw, field, kinds)
          list = raw.nil? ? [] : raw
          raise Refusal, "#{field} is a list" unless list.is_a?(Array)
          raise Refusal, "#{field} carries at most #{REVIEW_ITEMS} items" if list.length > REVIEW_ITEMS

          cleaned = list.each_with_index.map do |item, index|
            raise Refusal, "#{field}.#{index} is an object" unless item.is_a?(Hash)

            kind = item["kind"].to_s
            unless kinds.include?(kind)
              raise Refusal, "#{field}.#{index}.kind is one of #{kinds.join(", ")}; got #{kind.inspect}"
            end
            detail = item["detail"].to_s.strip
            raise Refusal, "#{field}.#{index}.detail is required" if detail.empty?
            raise Refusal, "#{field}.#{index}.detail is at most 2,000 characters" if
              detail.length > 2_000

            path = item["path"].to_s.strip
            raise Refusal, "#{field}.#{index}.path is at most 500 characters" if path.length > 500

            line = item["line"]
            if line && (!line.is_a?(Integer) || line < 1)
              raise Refusal, "#{field}.#{index}.line is a positive integer"
            end

            { "kind" => kind, "detail" => detail,
              "path" => path.empty? ? nil : path, "line" => line }.compact
          end
          [cleaned, nil]
        end

        def check_effect(effect, index)
          kind = effect["kind"].to_s
          unless KINDS.include?(kind)
            raise Refusal, "effect #{index} has kind #{kind.inspect}; known: #{KINDS.join(", ")}"
          end
          raise Refusal, "a whole-file effect is not a model proposal" if kind == "file"

          payload = effect["payload"].is_a?(Hash) ? effect["payload"] : {}
          if secret?(payload)
            raise Refusal, "effect #{index} contains a value that looks like a secret"
          end
          if kind == "rule"
            rule_kind = payload["kind"].to_s
            unless RULE_KINDS.include?(rule_kind)
              raise Refusal, "effect #{index} is a rule of kind #{rule_kind.inspect}; a model may " \
                             "propose #{RULE_KINDS.join(", ")}"
            end
            path = payload.dig("payload", "path").to_s
            refuse_path!(path, index) if path != ""
          else
            path = payload["path"].to_s
            refuse_path!(path, index) if path != ""
          end
          if %w[patch config].include?(kind) &&
              (payload["find"].to_s.empty? || payload["path"].to_s.empty?)
            raise Refusal, "effect #{index} is a #{kind} and needs a path and a find"
          end
          if kind == "gem" && payload["name"].to_s.empty?
            raise Refusal, "effect #{index} is a gem effect and needs a name"
          end
          if %w[delete chmod].include?(kind) && payload["path"].to_s.empty?
            raise Refusal, "effect #{index} is a #{kind} and needs a path"
          end

          phase = effect["phase"].to_s
          phase = "pre" if phase.empty?
          raise Refusal, "effect #{index} has phase #{phase.inspect}; it is pre or post" unless
            %w[pre post].include?(phase)

          { "kind" => kind, "payload" => payload,
            "applies_when" => effect["applies_when"].is_a?(Hash) ? effect["applies_when"] : {},
            "phase" => phase }
        end

        def refuse_path!(path, index)
          text = path.to_s.tr("\\", "/").delete_prefix("./")
          if text.start_with?("/") || text.split("/").include?("..")
            raise Refusal, "effect #{index} names a path outside the application"
          end
          if FORBIDDEN_PREFIXES.any? { |prefix| text.start_with?(prefix) } ||
              FORBIDDEN_BASENAMES.include?(text) ||
              FORBIDDEN_BASENAMES.include?(File.basename(text)) ||
              FORBIDDEN_EXTENSIONS.include?(File.extname(text))
            raise Refusal, "effect #{index} names #{path}, a path a model may not propose"
          end
        end

        def read_needs(raw)
          return [] if raw.nil?
          return "needs is a list" unless raw.is_a?(Array)
          return "at most 20 needs" if raw.length > 20

          raw.each_with_index.map do |item, index|
            raise Refusal, "need #{index} is not an object" unless item.is_a?(Hash)

            kind = item["kind"].to_s
            unless %w[question command file].include?(kind)
              raise Refusal, "need #{index} is question, command or file"
            end
            path = item["path"].to_s[0, 500]
            command = item["command"].to_s[0, 500]
            why = item["why"].to_s[0, 1000]
            { "kind" => kind, "path" => path.empty? ? nil : path,
              "command" => command.empty? ? nil : command,
              "why" => why.empty? ? nil : why }.compact
          end
        end
      end
    end
  end
end
