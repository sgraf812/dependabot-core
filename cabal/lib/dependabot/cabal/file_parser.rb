# frozen_string_literal: true

require "dependabot/dependency"
require "dependabot/file_parsers"
require "dependabot/file_parsers/base"
require "dependabot/cabal/requirement"
require "dependabot/cabal/version"
require "dependabot/errors"

module Dependabot
  module Cabal
    # Basically, we want to parse a list of Fields:
    # - https://github.com/haskell/cabal/blob/65d7cc6c127af18094f7f1bf86c0b00cada5d9e2/Cabal/Distribution/Fields/Field.hs#L37
    # That is, a sequence of
    # - fields (foo: blah) and
    # - sections (library bar\n  stuff: blarg)
    class GenericPackageDescription

      # Parse the top-level `packages:` field.
      # `String -> Array[String]`
      def self.parse_packages_field(input)
        m = @PACKAGES_PAYLOAD_REGEX.match(input)
        # The field payload is a comma and space-separated list of packages
        m[:payload].split(/[\s,]+/)
      end

      # Parse all `build-depends:` fields, regardless in which (sub-)sections
      # they occur.
      # `String -> Array[DependencySet]`
      def self.parse_build_depends_field(input)
        input.scan(@BUILD_DEPENDS_PAYLOAD_REGEX).map do |match|
          # The build-depends payload is a (optionally space, but necessarily)
          # comma-separated list of (library + version bound info).
          match[:payload].split(",").map do |entry|
            library_name, bounds = entry.split(/([a-zA-Z0-9\-]+)/, 2)[1..-1]
            # Now we only need to make sense of the bounds...
          end
        end
      end

      private

      def self.parse_field_payload_regex(field)
        # This regex takes care of indentation sensitivity around fields
        # in cabal.project and *.cabal files.
        # The <payload> capture group is what we are after: Basically the
        # contents of the field. It may spread over multiple lines, but every
        # line after the first must lead with more space than what is matched
        # by the <indent> capture group preceding the field declaration.
        # We allow empty lines and lines with only whitespace in-between,
        # though (the |[ \t]*) part), regardless of indentation.
        %r{
          (?<indent>[\ \t]*)#{field}: # Capture indentation of field declaration
          (?<payload>
            # Match the payload, consisting of
            # (1) The rest of the line
            [^\n]*
            # (2) And a run of zero or more following lines, as long as
            # (a) they are indented more than <indent> or (b) they consist
            # of whitespace only.
            (?:\n(?:\k<indent>[\ \t][^\n]+|[\ \t]*))*
            )
        }
      end

      @@PACKAGES_PAYLOAD_REGEX = parse_field_payload_regex("packages").freeze
      @@VERSION_PAYLOAD_REGEX = parse_field_payload_regex("build-depends").freeze
      @@BUILD_DEPENDS_PAYLOAD_REGEX = parse_field_payload_regex("build-depends").freeze
    end

    class FileParser < Dependabot::FileParsers::Base
      require "dependabot/file_parsers/base/dependency_set"

      @@DEPENDENCY_TYPES =
        %w(dependencies dev-dependencies build-dependencies).freeze

      def parse
        dependency_set = DependencySet.new
        dependency_set += manifest_dependencies
        dependency_set += freeze_file_dependencies if freeze_file

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

      def manifest_dependencies
        dependency_set = DependencySet.new

        manifest_files.each do |file|
          DEPENDENCY_TYPES.each do |type|
            parsed_file(file).fetch(type, {}).each do |name, requirement|
              next unless name == name_from_declaration(name, requirement)
              next if freeze_file && !version_from_freeze_file(name, requirement)

              dependency_set << build_dependency(name, requirement, type, file)
            end

            parsed_file(file).fetch("target", {}).each do |_, t_details|
              t_details.fetch(type, {}).each do |name, requirement|
                next unless name == name_from_declaration(name, requirement)
                next if freeze_file && !version_from_freeze_file(name, requirement)

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
          version: version_from_freeze_file(name, requirement),
          package_manager: "cabal",
          requirements: [{
            requirement: requirement_from_declaration(requirement),
            file: file.name,
            groups: [type],
            source: source_from_declaration(requirement)
          }]
        )
      end

      def freeze_file_dependencies
        dependency_set = DependencySet.new
        return dependency_set unless freeze_file

        parsed_file(freeze_file).fetch("package", []).each do |package_details|
          next unless package_details["source"]

          # TODO: This isn't quite right, as it will only give us one
          # version of each dependency (when in fact there are many)
          dependency_set << Dependency.new(
            name: package_details["name"],
            version: version_from_freeze_file_details(package_details),
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

      def version_from_freeze_file(name, declaration)
        return unless freeze_file

        candidate_packages =
          parsed_file(freeze_file).fetch("package", []).
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

        version_from_freeze_file_details(package)
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

      def version_from_freeze_file_details(package_details)
        unless package_details["source"]&.start_with?("git+")
          return package_details["version"]
        end

        package_details["source"].split("#").last
      end

      def check_required_files
        project_file = get_original_file("cabal.project")
        invalid_cabal_files =
          cabal_files.
            select { |f| !parse_cabal_file(f) }.
            map { |f| f.name }
        raise "No cabal.project or *.cabal file found." if
          !project_file && cabal_files.empty?
        raise "Could not find any cabal files listed in cabal.project." if
          project_file && cabal_files.empty?
        raise "Could not parse packages field of cabal.project file." if
          project_file && !parse_project_file(project_file)
        raise "Could not parse build-depends field of #{invalid_cabal_files}" if
          !invalid_cabal_files.empty?
        raise "Could not parse constraints field of #{freeze_file.name}" if
          !parse_freeze_file(freeze_file)
      end

      def parse_project_file(file)
        @parse_project_file ||=
          GenericPackageDescription.parse_packages_field(file.content)
      end

      # TODO: Maybe do the same with build-tool-depends?
      def parse_cabal_file(file)
        @parse_cabal_file ||=
          GenericPackageDescription.parse_build_depends_field(file.content)
      end

      def cabal_files
        @cabal_files ||=
          dependency_files.select { |f| f.name.end_with?(".cabal") }
      end

      def freeze_file
        @freeze_file ||= get_original_file("cabal.project.freeze")
      end

      def version_class
        Cabal::Version
      end
    end
  end
end

Dependabot::FileParsers.register("cabal", Dependabot::Cabal::FileParser)
