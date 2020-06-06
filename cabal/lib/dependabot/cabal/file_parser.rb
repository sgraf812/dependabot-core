# frozen_string_literal: true

require "toml-rb"

require "dependabot/dependency"
require "dependabot/file_parsers"
require "dependabot/file_parsers/base"
require "dependabot/cabal/requirement"
require "dependabot/cabal/version"
require "dependabot/errors"

module Dependabot
  module Haskell
    module Cabal
      # Basically, we want to parse a list of Fields:
      # - https://github.com/haskell/cabal/blob/65d7cc6c127af18094f7f1bf86c0b00cada5d9e2/Cabal/Distribution/Fields/Field.hs#L37
      # That is, a sequence of
      # - fields (foo: blah) and
      # - sections (library bar\n  stuff: blarg)
      class GenericPackageDescription
        # String -> Array[(String, (Field | Section))]
        def self.parse(input)
          GenericPackageDescription.parse_field_payload(Lexer.new(input))
        end

        def initialize
          @nestings = [] # Array[{:offset, :}]
        end

        private

        class Token
          @EOF = Token.new(type: "eof")
          @OPEN_INDENT = Token.new(type: "open_indent")
          @CLOSE_INDENT = Token.new(type: "close_indent")

          def ==(other)
            @type == other.type && @payload == other.payload
          end

          def self.new_word(payload)
            Token.new(type: "word", payload: payload)
          end

          private

          def initialize(type:, payload: nil)
            @type = type
            @payload = payload
          end
        end

        class Lexer
          def initialize(input)
            @next_tokens = []
            @input = input
            @i = 0
            @after_new_line = true
            @indents = []
            advance()
          end

          def next_token()
            return @next_tokens.first unless @next_tokens.empty?
            advance()
            @next_token.first
          end

          def cur()
            @input[@i]
          end

          def advance()
            return @next_token.shift unless @next_token.empty?

            while cur == '\n'
              @after_new_line = true
              @i += 1
            end

            offset = 0
            while cur == ' ' || cur == '\t'
              if cur == '\t' then
                # tab = 8 spaces because of https://github.com/haskell/cabal/blob/0046cf2dbde006320547ab26c3a17e5f009bc616/Cabal/Distribution/Fields/Lexer.hs#L73
                offset += 8
              else
                offset += 1
              end
                @i += 1
            end

            # ignore empty lines
            return advance if cur == '\n'

            if @after_new_line then
              while @indents[-1] <= offset
                @indents.pop
                @next_tokens << Token.CLOSE_INDENT
              end
              @after_new_line = false
            end

            start = @i
            @i += 1 while !cur.start_with?(" ", "\t", "\n")
            payload = @input[@start..(@i-1)]
            next_tokens << Token.new_word(payload)
          end
        end

        # (Integer, [Token]) -> Array[(String, (Field | Section))]
        # []
        def parse_field_payload(lexer)
          case lexer.next_token.type
          when
          end
        end
      end

      class FileParser < Dependabot::FileParsers::Base
        require "dependabot/file_parsers/base/dependency_set"

        DEPENDENCY_TYPES =
          %w(dependencies dev-dependencies build-dependencies).freeze

        def parse
          check_rust_workspace_root

          dependency_set = DependencySet.new
          dependency_set += manifest_dependencies
          dependency_set += lockfile_dependencies if lockfile

          dependencies = dependency_set.dependencies

          # TODO: Handle patched dependencies
          dependencies.reject! { |d| patched_dependencies.include?(d.name) }

          # TODO: Currently, Dependabot can't handle dependencies that have
          # multiple sources. Fix that!
          dependencies.reject do |dep|
            dep.requirements.map { |r| r.fetch(:source) }.uniq.count > 1
          end
        end

        private

        def check_rust_workspace_root
          cabal_project = dependency_files.find { |f| f.name == "cabal.project" }
          workspace_root = parsed_file(cabal_project).dig("package", "workspace")
          return unless workspace_root

          msg = "This project is part of a Rust workspace but is not the "\
                "workspace root."\

          if cabal_project.directory != "/"
            msg += "Please update your settings so Dependabot points at the "\
                  "workspace root instead of #{cabal_project.directory}."
          end
          raise Dependabot::DependencyFileNotEvaluatable, msg
        end

        def manifest_dependencies
          dependency_set = DependencySet.new

          manifest_files.each do |file|
            DEPENDENCY_TYPES.each do |type|
              parsed_file(file).fetch(type, {}).each do |name, requirement|
                next unless name == name_from_declaration(name, requirement)
                next if lockfile && !version_from_lockfile(name, requirement)

                dependency_set << build_dependency(name, requirement, type, file)
              end

              parsed_file(file).fetch("target", {}).each do |_, t_details|
                t_details.fetch(type, {}).each do |name, requirement|
                  next unless name == name_from_declaration(name, requirement)
                  next if lockfile && !version_from_lockfile(name, requirement)

                  dependency_set <<
                    build_dependency(name, requirement, type, file)
                end
              end
            end
          end

          dependency_set
        end

        def build_dependency(name, requirement, type, file)
          Dependency.new(
            name: name,
            version: version_from_lockfile(name, requirement),
            package_manager: "cabal",
            requirements: [{
              requirement: requirement_from_declaration(requirement),
              file: file.name,
              groups: [type],
              source: source_from_declaration(requirement)
            }]
          )
        end

        def lockfile_dependencies
          dependency_set = DependencySet.new
          return dependency_set unless lockfile

          parsed_file(lockfile).fetch("package", []).each do |package_details|
            next unless package_details["source"]

            # TODO: This isn't quite right, as it will only give us one
            # version of each dependency (when in fact there are many)
            dependency_set << Dependency.new(
              name: package_details["name"],
              version: version_from_lockfile_details(package_details),
              package_manager: "cabal",
              requirements: []
            )
          end

          dependency_set
        end

        def patched_dependencies
          root_manifest = manifest_files.find { |f| f.name == "cabal.project" }
          return [] unless parsed_file(root_manifest)["patch"]

          parsed_file(root_manifest)["patch"].values.flat_map(&:keys)
        end

        def requirement_from_declaration(declaration)
          if declaration.is_a?(String)
            return declaration == "" ? nil : declaration
          end
          unless declaration.is_a?(Hash)
            raise "Unexpected dependency declaration: #{declaration}"
          end
          if declaration["version"]&.is_a?(String) && declaration["version"] != ""
            return declaration["version"]
          end

          nil
        end

        def name_from_declaration(name, declaration)
          return name if declaration.is_a?(String)
          unless declaration.is_a?(Hash)
            raise "Unexpected dependency declaration: #{declaration}"
          end

          declaration.fetch("package", name)
        end

        def source_from_declaration(declaration)
          return if declaration.is_a?(String)
          unless declaration.is_a?(Hash)
            raise "Unexpected dependency declaration: #{declaration}"
          end

          return git_source_details(declaration) if declaration["git"]
          return { type: "path" } if declaration["path"]
        end

        def version_from_lockfile(name, declaration)
          return unless lockfile

          candidate_packages =
            parsed_file(lockfile).fetch("package", []).
            select { |p| p["name"] == name }

          if (req = requirement_from_declaration(declaration))
            req = Cabal::Requirement.new(req)

            candidate_packages =
              candidate_packages.
              select { |p| req.satisfied_by?(version_class.new(p["version"])) }
          end

          candidate_packages =
            candidate_packages.
            select do |p|
              git_req?(declaration) ^ !p["source"]&.start_with?("git+")
            end

          package =
            candidate_packages.
            max_by { |p| version_class.new(p["version"]) }

          return unless package

          version_from_lockfile_details(package)
        end

        def git_req?(declaration)
          source_from_declaration(declaration)&.fetch(:type, nil) == "git"
        end

        def git_source_details(declaration)
          {
            type: "git",
            url: declaration["git"],
            branch: declaration["branch"],
            ref: declaration["tag"] || declaration["rev"]
          }
        end

        def version_from_lockfile_details(package_details)
          unless package_details["source"]&.start_with?("git+")
            return package_details["version"]
          end

          package_details["source"].split("#").last
        end

        def check_required_files
          raise "No cabal.project!" unless get_original_file("cabal.project")
        end

        def parsed_file(file)
          @parsed_file ||= {}
          @parsed_file[file.name] ||= TomlRB.parse(file.content)
        rescue TomlRB::ParseError, TomlRB::ValueOverwriteError
          raise Dependabot::DependencyFileNotParseable, file.path
        end

        def manifest_files
          @manifest_files ||=
            dependency_files.
            select { |f| f.name.end_with?("cabal.project") }.
            reject(&:support_file?)
        end

        def lockfile
          @lockfile ||= get_original_file("cabal.config")
        end

        def version_class
          Cabal::Version
        end
      end
    end
  end
end

Dependabot::FileParsers.register("cabal", Dependabot::Cabal::FileParser)
