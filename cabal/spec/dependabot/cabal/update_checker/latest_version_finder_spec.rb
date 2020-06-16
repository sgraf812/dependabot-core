# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/cabal/update_checker/latest_version_finder"

RSpec.describe Dependabot::Cabal::UpdateChecker::LatestVersionFinder do
  before do
    stub_request(:get, hackage_url).to_return(status: 200, body: hackage_response)
  end
  let(:hackage_url) { "https://hackage.haskell.org/package/#{dependency_name}/preferred.json" }
  let(:hackage_response) { fixture("hackage_responses", hackage_fixture_name) }
  let(:hackage_fixture_name) { "#{dependency_name}.preferred.json" }

  let(:finder) do
    described_class.new(
      dependency: dependency,
      dependency_files: dependency_files,
      credentials: credentials,
      ignored_versions: ignored_versions,
      raise_on_ignored: raise_on_ignored,
      security_advisories: security_advisories
    )
  end

  let(:ignored_versions) { [] }
  let(:raise_on_ignored) { false }
  let(:security_advisories) { [] }
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:dependency_files) do
    [
      Dependabot::DependencyFile.new(
        name: "cabal.project",
        content: fixture("manifests", manifest_fixture_name)
      ),
      Dependabot::DependencyFile.new(
        name: "cabal.project.freeze",
        content: fixture("lockfiles", lockfile_fixture_name)
      )
    ]
  end
  let(:manifest_fixture_name) { "bare_version_specified" }
  let(:lockfile_fixture_name) { "bare_version_specified" }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: requirements,
      package_manager: "cabal"
    )
  end
  let(:requirements) do
    [{ file: "cabal.project", requirement: "0.1.12", groups: [], source: nil }]
  end
  let(:dependency_name) { "pomaps" }
  let(:dependency_version) { "0.1.0.0" }

  describe "#latest_version" do
    subject { finder.latest_version }
    it { is_expected.to eq(Gem::Version.new("0.2.0.0")) }

    context "when the latest version is being ignored" do
      let(:ignored_versions) { [">= 0.2.0.0, < 0.2.0.1"] }
      it { is_expected.to eq(Gem::Version.new("0.1.0.0")) }
    end

    context "when the hackage link resolves to a redirect" do
      let(:redirect_url) { "https://crates.io/api/v1/crates/Time" }

      before do
        stub_request(:get, hackage_url).
          to_return(status: 302, headers: { "Location" => redirect_url })
        stub_request(:get, redirect_url).
          to_return(status: 200, body: hackage_response)
      end

      it { is_expected.to eq(Gem::Version.new("0.2.0.0")) }
    end

    context "when the hackage link fails at first" do
      before do
        stub_request(:get, hackage_url).
          to_raise(Excon::Error::Timeout).then.
          to_return(status: 200, body: hackage_response)
      end

      it { is_expected.to eq(Gem::Version.new("0.2.0.0")) }
    end

    context "when the hackage link resolves to a 'Not Found' page" do
      before do
        stub_request(:get, hackage_url).
          to_return(status: 404, body: hackage_response)
      end
      let(:hackage_fixture_name) { "not_found.json" }

      it { is_expected.to be_nil }
    end

    #context "when the latest version is a pre-release" do
    #  let(:dependency_name) { "xdg" }
    #  let(:dependency_version) { "2.0.0" }
    #  it { is_expected.to eq(Gem::Version.new("2.1.0")) }

    #  context "and the user wants a pre-release" do
    #    context "because their current version is a pre-release" do
    #      let(:dependency_version) { "2.0.0-pre4" }
    #      it { is_expected.to eq(Gem::Version.new("3.0.0-pre1")) }
    #    end

    #    context "because their requirements say they want pre-releases" do
    #      let(:requirements) do
    #        [{
    #          file: "cabal.project",
    #          requirement: "~2.0.0-pre1",
    #          groups: ["dependencies"],
    #          source: nil
    #        }]
    #      end
    #      it { is_expected.to eq(Gem::Version.new("3.0.0-pre1")) }
    #    end
    #  end
    #end
  end

  #describe "#lowest_security_fix_version" do
  #  subject { finder.lowest_security_fix_version }

  #  let(:dependency_name) { "time" }
  #  let(:dependency_version) { "0.1.12" }
  #  let(:security_advisories) do
  #    [
  #      Dependabot::SecurityAdvisory.new(
  #        dependency_name: dependency_name,
  #        package_manager: "cabal",
  #        vulnerable_versions: ["<= 0.1.18"]
  #      )
  #    ]
  #  end
  #  it { is_expected.to eq(Gem::Version.new("0.1.19")) }

  #  context "when the lowest version is being ignored" do
  #    let(:ignored_versions) { [">= 0.1.18, < 0.1.20"] }
  #    it { is_expected.to eq(Gem::Version.new("0.1.20")) }
  #  end

  #  context "when all versions are being ignored" do
  #    let(:ignored_versions) { [">= 0"] }
  #    it "returns nil" do
  #      expect(subject).to be_nil
  #    end

  #    context "raise_on_ignored" do
  #      let(:raise_on_ignored) { true }
  #      it "raises an error" do
  #        expect { subject }.to raise_error(Dependabot::AllVersionsIgnored)
  #      end
  #    end
  #  end

  #  context "when the lowest fixed version is a pre-release" do
  #    let(:dependency_name) { "xdg" }
  #    let(:dependency_version) { "1.0.0" }
  #    let(:security_advisories) do
  #      [
  #        Dependabot::SecurityAdvisory.new(
  #          dependency_name: dependency_name,
  #          package_manager: "cabal",
  #          vulnerable_versions: ["<= 2.0.0-pre2"]
  #        )
  #      ]
  #    end
  #    it { is_expected.to eq(Gem::Version.new("2.0.0")) }

  #    context "and the user wants a pre-release" do
  #      context "because their current version is a pre-release" do
  #        let(:dependency_version) { "2.0.0-pre1" }
  #        it { is_expected.to eq(Gem::Version.new("2.0.0-pre3")) }
  #      end

  #      context "because their requirements say they want pre-releases" do
  #        let(:requirements) do
  #          [{
  #            file: "cabal.project",
  #            requirement: "~2.0.0-pre1",
  #            groups: ["dependencies"],
  #            source: nil
  #          }]
  #        end
  #        it { is_expected.to eq(Gem::Version.new("2.0.0-pre3")) }
  #      end
  #    end
  #  end
  #end
end
