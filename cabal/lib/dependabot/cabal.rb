# frozen_string_literal: true

# These all need to be required so the various classes can be registered in a
# lookup table of package manager names to concrete classes.
require "dependabot/cabal/file_fetcher"
require "dependabot/cabal/file_parser"
require "dependabot/cabal/update_checker"
require "dependabot/cabal/file_updater"
require "dependabot/cabal/metadata_finder"
require "dependabot/cabal/requirement"
require "dependabot/cabal/version"

require "dependabot/pull_request_creator/labeler"
Dependabot::PullRequestCreator::Labeler.
  register_label_details("cabal", name: "rust", colour: "000000")

require "dependabot/dependency"
Dependabot::Dependency.register_production_check("cabal", ->(_) { true })
