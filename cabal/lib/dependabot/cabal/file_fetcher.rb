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
        # Cabal v1 single package project
        return true if filenames.any? { |name| name.end_with?(".cabal") }
        # Cabal v2 multipackage project
        return true if filenames.include?("cabal.project")
        return false
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
          fetched_files << fetch_multi_package_project(cabal_project_file) if cabal_project
        else
          # simple project, single cabal file (compatible with v1)
          fetched_files << fetch_simple_project unless cabal_project_file
        end
        fetched_files << cabal_project_freeze_file if cabal_project_freeze_file
        fetched_files.uniq
      end

      # Seems reasonable to expect 100_000 as max file size, see python
      def text_file?(file, max_size = 100_000)
        file.type == "file"
          && file.size < 100_000
          && file.content.valid_encoding?
      end

      def project_file?(file)
        text_file?(file) && file.name == "cabal.project"
      end

      def cabal_file?(file)
        text_file?(file) && file.name.end_with?(".cabal")
      end

      #
      # Single package project (Cabal v1 style), without cabal.project file
      #
      def fetch_simple_project
        @files = []

        repo_contents.
          select { |f| cabal_file?(".cabal") }.
          each { |f| @files << fetch_file_from_host(f.name) }

        raise "Multiple valid .cabal files found!" if @files.length > 1
        raise "No valid .cabal file found!" if @files.empty?

        @files.first
      end


      #
      # Cabal v2 style (multi) package project, with cabal.project file
      #
      def fetch_multi_package_project(project_file)
        @files = []

        repo_contents.
          select { |f| cabal_file?(".cabal") }.
          each { |f| @files << fetch_file_from_host(f.name) }

        # We could throw an error if there are zero or multiple files, but
        # probably not worth it.
        @files.first
      end

      def cabal_project_file
        @cabal_project_file ||= fetch_file_from_host("cabal.project")
      end


      # Cabal v2 freeze files. Can be used without cabal.project!
      def cabal_project_freeze_file
        @cabal_project_freeze_file ||= fetch_file_from_host("cabal.project.freeze")
      end
  end
end

Dependabot::FileFetchers.register("Cabal", Dependabot::Cabal::FileFetcher)
