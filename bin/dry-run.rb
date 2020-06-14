#!/usr/bin/env ruby
# frozen_string_literal: true

# This script is does a full update run for a given repo (optionally for a
# specific dependency only), and shows the proposed changes to any dependency
# files without actually creating a pull request.
#
# It's used regularly by the Dependabot team to manually debug issues, so
# should always be up-to-date.
#
# Usage:
#   ruby bin/dry-run.rb [OPTIONS] PACKAGE_MANAGER GITHUB_REPO
#
# ! You'll need to have a GitHub access token (a personal access token is
# ! fine) available as the environment variable LOCAL_GITHUB_ACCESS_TOKEN.
#
# Example:
#   ruby bin/dry-run.rb go_modules zonedb/zonedb
#
# Package managers:
# - bundler
# - pip (includes pipenv)
# - npm_and_yarn
# - maven
# - gradle
# - cabal
# - cargo
# - hex
# - composer
# - nuget
# - dep
# - go_modules
# - elm
# - submodules
# - docker
# - terraform

# rubocop:disable Style/GlobalVars

$LOAD_PATH << "./bundler/lib"
$LOAD_PATH << "./cabal/lib"
$LOAD_PATH << "./cargo/lib"
$LOAD_PATH << "./common/lib"
$LOAD_PATH << "./composer/lib"
$LOAD_PATH << "./dep/lib"
$LOAD_PATH << "./docker/lib"
$LOAD_PATH << "./elm/lib"
$LOAD_PATH << "./git_submodules/lib"
$LOAD_PATH << "./github_actions/lib"
$LOAD_PATH << "./go_modules/lib"
$LOAD_PATH << "./gradle/lib"
$LOAD_PATH << "./hex/lib"
$LOAD_PATH << "./maven/lib"
$LOAD_PATH << "./npm_and_yarn/lib"
$LOAD_PATH << "./nuget/lib"
$LOAD_PATH << "./python/lib"
$LOAD_PATH << "./terraform/lib"

require "bundler"
ENV["BUNDLE_GEMFILE"] = File.join(__dir__, "../omnibus/Gemfile")
Bundler.setup

require "optparse"
require "json"
require "byebug"

require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"

require "dependabot/bundler"
require "dependabot/cabal"
require "dependabot/cargo"
require "dependabot/composer"
require "dependabot/dep"
require "dependabot/docker"
require "dependabot/elm"
require "dependabot/git_submodules"
require "dependabot/github_actions"
require "dependabot/go_modules"
require "dependabot/gradle"
require "dependabot/hex"
require "dependabot/maven"
require "dependabot/npm_and_yarn"
require "dependabot/nuget"
require "dependabot/python"
require "dependabot/terraform"

# GitHub credentials with write permission to the repo you want to update
# (so that you can create a new branch, commit and pull request).
# If using a private registry it's also possible to add details of that here.

$options = {
  credentials: [],
  directory: "/",
  dependency_name: nil,
  branch: nil,
  cache_steps: [],
  write: false,
  lockfile_only: false,
  requirements_update_strategy: nil,
  commit: nil
}

unless ENV["LOCAL_GITHUB_ACCESS_TOKEN"].to_s.strip.empty?
  $options[:credentials] << {
    "type" => "git_source",
    "host" => "github.com",
    "username" => "x-access-token",
    "password" => ENV["LOCAL_GITHUB_ACCESS_TOKEN"]
  }
end

unless ENV["LOCAL_CONFIG_VARIABLES"].to_s.strip.empty?
  # For example:
  # "[{\"type\":\"npm_registry\",\"registry\":\
  #     "registry.npmjs.org\",\"token\":\"123\"}]"
  $options[:credentials].concat(JSON.parse(ENV["LOCAL_CONFIG_VARIABLES"]))
end

option_parse = OptionParser.new do |opts|
  opts.banner = "usage: ruby bin/dry-run.rb [OPTIONS] PACKAGE_MANAGER REPO"

  opts.on("--dir DIRECTORY", "Dependency file directory") do |value|
    $options[:directory] = value
  end

  opts.on("--branch BRANCH", "Repo branch") do |value|
    $options[:branch] = value
  end

  opts.on("--dep DEPENDENCY", "Dependency to update") do |value|
    $options[:dependency_name] = value
  end

  opts.on("--cache STEPS", "Cache e.g. files, dependencies") do |value|
    $options[:cache_steps].concat(value.split(",").map(&:strip))
  end

  opts.on("--write", "Write the update to the cache directory") do |_value|
    $options[:write] = true
  end

  opts.on("--lockfile-only", "Only update the lockfile") do |_value|
    $options[:lockfile_only] = true
  end

  opts_req_desc = "Options: auto, widen_ranges, bump_versions or "\
                         "bump_versions_if_necessary"
  opts.on("--requirements-update-strategy STRATEGY", opts_req_desc) do |value|
    value = nil if value == "auto"
    $options[:requirements_update_strategy] = value
  end

  opts.on("--commit COMMIT", "Commit to fetch dependency files from") do |value|
    $options[:commit] = value
  end
end

option_parse.parse!

# Full name of the GitHub repo you want to create pull requests for
if ARGV.length < 2
  puts option_parse.help
  exit 1
end

$package_manager, $repo_name = ARGV

def show_diff(original_file, updated_file)
  if original_file.content == updated_file.content
    puts "    no change to #{original_file.name}"
    return
  end

  original_tmp_file = Tempfile.new("original")
  original_tmp_file.write(original_file.content)
  original_tmp_file.close

  updated_tmp_file = Tempfile.new("updated")
  updated_tmp_file.write(updated_file.content)
  updated_tmp_file.close

  diff = `diff #{original_tmp_file.path} #{updated_tmp_file.path}`
  puts
  puts "    ± #{original_file.name}"
  puts "    ~~~"
  puts diff.lines.map { |line| "    " + line }.join("")
  puts "    ~~~"
end

def cached_read(name)
  raise "Provide something to cache" unless block_given?
  return yield unless $options[:cache_steps].include?(name)

  cache_path = File.join("tmp", $repo_name.split("/"), "cache", "#{name}.bin")
  cache_dir = File.dirname(cache_path)
  FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
  cached = File.read(cache_path) if File.exist?(cache_path)
  # rubocop:disable Security/MarshalLoad
  return Marshal.load(cached) if cached

  # rubocop:enable Security/MarshalLoad

  data = yield
  File.write(cache_path, Marshal.dump(data))
  data
end

def dependency_files_cache_dir
  branch = $options[:branch] || ""
  dir = $options[:directory]
  File.join("dry-run", $repo_name.split("/"), branch, dir)
end

# rubocop:disable Metrics/AbcSize
# rubocop:disable Metrics/MethodLength
# rubocop:disable Metrics/CyclomaticComplexity
# rubocop:disable Metrics/PerceivedComplexity
def cached_dependency_files_read
  cache_dir = dependency_files_cache_dir
  cache_manifest_path = File.join(
    cache_dir, "cache-manifest-#{$package_manager}.json"
  )
  FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)

  if File.exist?(cache_manifest_path)
    cached_manifest = File.read(cache_manifest_path)
  end
  cached_dependency_files = JSON.parse(cached_manifest) if cached_manifest

  all_files_cached = cached_dependency_files&.all? do |file|
    File.exist?(File.join(cache_dir, file["name"]))
  end

  if all_files_cached && $options[:cache_steps].include?("files")
    puts "=> reading dependency files from cache: ./#{cache_dir}"
    cached_dependency_files.map do |file|
      file_content = File.read(File.join(cache_dir, file["name"]))
      Dependabot::DependencyFile.new(
        name: file["name"],
        content: file_content,
        directory: file["directory"] || "/",
        support_file: file["support_file"] || false,
        symlink_target: file["symlink_target"] || nil,
        type: file["type"] || "file"
      )
    end
  else
    if $options[:cache_steps].include?("files")
      puts "=> failed to read all dependency files from cache manifest: "\
           "./#{cache_manifest_path}"
    end
    puts "=> fetching dependency files"
    data = yield
    puts "=> dumping fetched dependency files: ./#{cache_dir}"
    manifest_data = data.map do |file|
      {
        name: file.name,
        directory: file.directory,
        symlink_target: file.symlink_target,
        support_file: file.support_file,
        type: file.type
      }
    end
    File.write(cache_manifest_path, JSON.pretty_generate(manifest_data))
    data.map do |file|
      files_path = File.join(cache_dir, file.name)
      files_dir = File.dirname(files_path)
      FileUtils.mkdir_p(files_dir) unless Dir.exist?(files_dir)
      File.write(files_path, file.content)
    end
    # Initialize a git repo so that changed files can be diffed
    if $options[:write]
      if File.exist?(".gitignore")
        FileUtils.cp(".gitignore", File.join(cache_dir, ".gitignore"))
      end
      Dir.chdir(cache_dir) do
        system("git init . && git add . && git commit --allow-empty -m 'Init'")
      end
    end
    data
  end
end
# rubocop:enable Metrics/PerceivedComplexity
# rubocop:enable Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/AbcSize

source = Dependabot::Source.new(
  provider: "github",
  repo: $repo_name,
  directory: $options[:directory],
  branch: $options[:branch],
  commit: $options[:commit]
)

$files = cached_dependency_files_read do
  fetcher = Dependabot::FileFetchers.for_package_manager($package_manager).
            new(source: source, credentials: $options[:credentials])
  fetcher.files
end

# Parse the dependency files
puts "=> parsing dependency files"
parser = Dependabot::FileParsers.for_package_manager($package_manager).new(
  dependency_files: $files,
  source: source,
  credentials: $options[:credentials]
)

dependencies = cached_read("dependencies") { parser.parse }

if $options[:dependency_name].nil?
  dependencies.select!(&:top_level?)
else
  dependencies.select! { |d| d.name == $options[:dependency_name] }
end

def update_checker_for(dependency)
  Dependabot::UpdateCheckers.for_package_manager($package_manager).new(
    dependency: dependency,
    dependency_files: $files,
    credentials: $options[:credentials],
    requirements_update_strategy: $options[:requirements_update_strategy],
    ignored_versions: ignore_conditions_for(dependency),
    security_advisories: security_advisories_for(dependency)
  )
end

# TODO: Parse from config file
def ignore_conditions_for(_)
  # Array of version requirements, e.g. ["4.x", "5.x"]
  []
end

# TODO: Parse from config file
def security_advisories_for(dependency)
  # Array of version requirement ranges, e.g. affected_versions: ["< 3.5.1"]
  advisories = [{
    dependency_name: dependency.name,
    patched_versions: [],
    unaffected_versions: [],
    affected_versions: []
  }]

  advisories.map do |adv|
    vulnerable_versions = adv[:affected_versions] || []
    safe_versions = (adv[:patched_versions] || []) +
                    (adv[:unaffected_versions] || [])

    Dependabot::SecurityAdvisory.new(
      dependency_name: dependency.name,
      package_manager: $package_manager,
      vulnerable_versions: vulnerable_versions,
      safe_versions: safe_versions
    )
  end
end

def peer_dependencies_can_update?(checker, reqs_to_unlock)
  checker.updated_dependencies(requirements_to_unlock: reqs_to_unlock).
    reject { |dep| dep.name == checker.dependency.name }.
    any? do |dep|
      original_peer_dep = ::Dependabot::Dependency.new(
        name: dep.name,
        version: dep.previous_version,
        requirements: dep.previous_requirements,
        package_manager: dep.package_manager
      )
      update_checker_for(original_peer_dep).
        can_update?(requirements_to_unlock: :own)
    end
end

def file_updater_for(dependencies)
  Dependabot::FileUpdaters.for_package_manager($package_manager).new(
    dependencies: dependencies,
    dependency_files: $files,
    credentials: $options[:credentials]
  )
end

def generate_dependency_files_for(updated_dependencies)
  if updated_dependencies.count == 1
    updated_dependency = updated_dependencies.first
    puts " => updating #{updated_dependency.name} from " \
         "#{updated_dependency.previous_version} to " \
         "#{updated_dependency.version}"
  else
    dependency_names = updated_dependencies.map(&:name)
    puts " => updating #{dependency_names.join(', ')}"
  end

  updater = file_updater_for(updated_dependencies)
  updater.updated_dependency_files
end

puts "=> updating #{dependencies.count} dependencies"

# rubocop:disable Metrics/BlockLength
dependencies.each do |dep|
  puts "\n=== #{dep.name} (#{dep.version})"
  checker = update_checker_for(dep)

  puts " => checking for updates"
  puts " => latest version from registry is #{checker.latest_version}"
  puts " => latest resolvable version is #{checker.latest_resolvable_version}"

  if checker.up_to_date?
    puts "    (no update needed)"
    next
  end

  requirements_to_unlock =
    if $options[:lockfile_only] || !checker.requirements_unlocked_or_can_be?
      if checker.can_update?(requirements_to_unlock: :none) then :none
      else :update_not_possible
      end
    elsif checker.can_update?(requirements_to_unlock: :own) then :own
    elsif checker.can_update?(requirements_to_unlock: :all) then :all
    else :update_not_possible
    end

  puts " => requirements to unlock: #{requirements_to_unlock}"

  if checker.respond_to?(:requirements_update_strategy)
    puts " => requirements update strategy: "\
         "#{checker.requirements_update_strategy}"
  end

  if requirements_to_unlock == :update_not_possible
    puts "    (no update possible)"
    next
  end

  updated_deps = checker.updated_dependencies(
    requirements_to_unlock: requirements_to_unlock
  )

  if peer_dependencies_can_update?(checker, requirements_to_unlock)
    puts "    (no update possible, peer dependency can be updated)"
    next
  end

  updated_files = generate_dependency_files_for(updated_deps)

  # Currently unused but used to create pull requests (from the updater)
  updated_deps.reject do |d|
    next false if d.name == checker.dependency.name
    next true if d.requirements == d.previous_requirements

    d.version == d.previous_version
  end

  if $options[:write]
    updated_files.each do |updated_file|
      path = File.join(dependency_files_cache_dir, updated_file.name)
      puts " => writing updated file ./#{path}"
      File.write(path, updated_file.content)
    end
  end

  updated_files.each do |updated_file|
    original_file = $files.find { |f| f.name == updated_file.name }
    show_diff(original_file, updated_file)
  end
end
# rubocop:enable Metrics/BlockLength

# rubocop:enable Style/GlobalVars
