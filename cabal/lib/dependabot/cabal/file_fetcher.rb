# frozen_string_literal: true

require "pathname"
require "toml-rb"

require "dependabot/file_fetchers"
require "dependabot/file_fetchers/base"
require "dependabot/cabal/file_parser"

# Docs on multipackage Cabal projects:
# https://cabal.readthedocs.io/en/latest/nix-local-build.html#developing-multiple-packages
module Dependabot
  module Cabal
    class FileFetcher < Dependabot::FileFetchers::Base
      def self.required_files_in?(filenames)
        # Implicit v1-style ./*.cabal project
        filenames.any? { |name| name.end_with?(".cabal") } ||
        # Cabal v2 multipackage project
        filenames.include?("cabal.project")
      end

      def self.required_files_message
        "Repo must contain a cabal.project or *.cabal file."
      end

      private

      def fetch_files
        fetched_files = []
        if cabal_project_file then
          # v2 style, possibly multiple packages with own cabal files
          fetched_files << cabal_project_file
          fetched_files += fetch_multi_package_project(cabal_project_file)
        else
          # simple project without cabal.project file, defaulting to ./*.cabal glob
          fetched_files += fetch_simple_project
        end
        fetched_files << cabal_project_freeze_file if cabal_project_freeze_file
        fetched_files.uniq
      end

      #
      # Simple project layout with implicit cabal.project file, having
      # `./*.cabal` as `packages`.
      #
      def fetch_simple_project
        files = []

        # What `expand_path("./*.cabal")` should do, but hardcoded for now
        repo_contents.
          select { |f| cabal_file?(f) }.
          each { |f| files << fetch_file_from_host(f.name) }

        raise "No valid .cabal file found!" if files.empty?

        files
      end

      # Seems reasonable to expect 100_000 as max file size, see python
      def text_file?(file, max_size = 100_000)
        file.type == "file" &&
        file.size < max_size
      end

      def cabal_file?(file)
        text_file?(file) && file.name.end_with?(".cabal")
      end

      # See https://cabal.readthedocs.io/en/latest/cabal-project.html#specifying-the-local-packages
      # Currently we only support (1). But (2) is also quite common. Hence
      # TODO: Implement support for globs (2). Cabal supports * in dir and file
      #       position. Also see #expand_path from NPM's FileFetcher.
      def expand_path(path)
        return [] if path.start_with?(%r{(https?|file)://}) # No URLs
        cleaned_path = Pathname.new(path).cleanpath
        return [] if cleaned_path.absolute?                 # No absolute paths
        return [] if cleaned_path.end_with?(".tar.gz")      # No tarballs

        if cleaned_path.ext_name.empty? then
          # basename is a dir and the cabal file is under dir/dir.cabal, see (1)
          cleaned_path = (cleaned_path + cleaned_path.basename).sub_ext(".cabal")
        end

        # Now cleaned_path points to a (hypothetical) cabal file
        [fetch_file_from_host(cleaned_path.to_path)].compact
      end

      #
      # Cabal v2 style (multi) package project, with cabal.project file
      #
      def fetch_multi_package_project(project_file)
        GenericPackageDescription.
          parse_packages_field(project_file.content).
          flat_map { |f| expand_path(paths) }
      end

      def cabal_project_file
        @cabal_project_file ||= fetch_file_if_present("cabal.project")
      end

      # Freeze files, as produced by cabal v2-freeze.
      def cabal_project_freeze_file
        @cabal_project_freeze_file ||= fetch_file_if_present("cabal.project.freeze")
      end
    end
  end
end

Dependabot::FileFetchers.register("cabal", Dependabot::Cabal::FileFetcher)
