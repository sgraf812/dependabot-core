# frozen_string_literal: true

require "spec_helper"
require "dependabot/cabal/file_fetcher"
require_common_spec "file_fetchers/shared_examples_for_file_fetchers"

RSpec.describe Dependabot::Cabal::FileFetcher do
  it_behaves_like "a dependency file fetcher"

  let(:source) do
    Dependabot::Source.new(
      provider: "github",
      repo: "gocardless/bump",
      directory: "/"
    )
  end
  let(:file_fetcher_instance) do
    described_class.new(source: source, credentials: credentials)
  end
  let(:url) { "https://api.github.com/repos/gocardless/bump/contents/" }
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end

  let(:json_header) { { "content-type" => "application/json" } }
  before { allow(file_fetcher_instance).to receive(:commit).and_return("sha") }
  before do
    stub_request(:get, url + "cabal.project?ref=sha").
      with(headers: { "Authorization" => "token token" }).
      to_return(
        status: 200,
        body: fixture("github", "contents_cabal_manifest.json"),
        headers: json_header
      )

    stub_request(:get, url + "cabal.project.freeze?ref=sha").
      with(headers: { "Authorization" => "token token" }).
      to_return(
        status: 200,
        body: fixture("github", "contents_cabal_lockfile.json"),
        headers: json_header
      )
  end

  context "with a lockfile" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_with_lockfile.json"),
          headers: json_header
        )
    end

    it "fetches the cabal.project and cabal.project.freeze" do
      expect(file_fetcher_instance.files.map(&:name)).
        to match_array(%w(cabal.project.freeze cabal.project))
    end
  end

  context "without a lockfile" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_without_lockfile.json"),
          headers: json_header
        )
      stub_request(:get, url + "cabal.project.freeze?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 404, headers: json_header)
    end

    it "fetches the cabal.project" do
      expect(file_fetcher_instance.files.map(&:name)).
        to eq(["cabal.project"])
    end
  end

  context "with a rust-toolchain file" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_with_toolchain.json"),
          headers: json_header
        )

      stub_request(:get, url + "rust-toolchain?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_lockfile.json"),
          headers: json_header
        )
    end

    it "fetches the cabal.project and rust-toolchain" do
      expect(file_fetcher_instance.files.map(&:name)).
        to match_array(%w(cabal.project rust-toolchain))
    end
  end

  context "with a path dependency" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_without_lockfile.json"),
          headers: json_header
        )
      stub_request(:get, url + "cabal.project?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 200, body: parent_fixture, headers: json_header)
    end
    let(:parent_fixture) do
      fixture("github", "contents_cabal_manifest_path_deps.json")
    end

    context "that is fetchable" do
      before do
        stub_request(:get, url + "src/s3/cabal.project?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: path_dep_fixture, headers: json_header)
      end
      let(:path_dep_fixture) do
        fixture("github", "contents_cabal_manifest.json")
      end

      it "fetches the path dependency's cabal.project" do
        expect(file_fetcher_instance.files.map(&:name)).
          to match_array(%w(cabal.project src/s3/cabal.project))
        expect(file_fetcher_instance.files.last.support_file?).
          to eq(true)
      end

      context "with a trailing slash in the path" do
        let(:parent_fixture) do
          fixture(
            "github",
            "contents_cabal_manifest_path_deps_trailing_slash.json"
          )
        end

        it "fetches the path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project src/s3/cabal.project))
        end
      end

      context "for a target dependency" do
        let(:parent_fixture) do
          fixture(
            "github",
            "contents_cabal_manifest_target_path_deps.json"
          )
        end

        it "fetches the path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project src/s3/cabal.project))
        end
      end

      context "for a replacement source" do
        let(:parent_fixture) do
          fixture("github", "contents_cabal_manifest_replacement_path.json")
        end

        it "fetches the path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project src/s3/cabal.project))
        end
      end

      context "for a patched source" do
        let(:parent_fixture) do
          fixture("github", "contents_cabal_manifest_patched_path.json")
        end

        it "fetches the path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project src/s3/cabal.project))
        end
      end

      context "when a git source is also specified" do
        let(:parent_fixture) do
          fixture("github", "contents_cabal_manifest_path_deps_alt_source.json")
        end

        before do
          stub_request(:get, url + "gen/photoslibrary1/cabal.project?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(status: 200, body: path_dep_fixture, headers: json_header)
        end

        it "fetches the path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project gen/photoslibrary1/cabal.project))
        end
      end

      context "with a directory" do
        let(:source) do
          Dependabot::Source.new(
            provider: "github",
            repo: "gocardless/bump",
            directory: "my_dir/"
          )
        end

        let(:url) do
          "https://api.github.com/repos/gocardless/bump/contents/my_dir/"
        end
        before do
          stub_request(:get, "https://api.github.com/repos/gocardless/bump/"\
                             "contents/my_dir?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(
              status: 200,
              body: fixture("github", "contents_cabal_without_lockfile.json"),
              headers: json_header
            )
        end

        it "fetches the path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project src/s3/cabal.project))
          expect(file_fetcher_instance.files.map(&:path)).
            to match_array(%w(/my_dir/cabal.project /my_dir/src/s3/cabal.project))
        end
      end

      context "and includes another path dependency" do
        let(:path_dep_fixture) do
          fixture("github", "contents_cabal_manifest_path_deps.json")
        end

        before do
          stub_request(:get, url + "src/s3/src/s3/cabal.project?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(
              status: 200,
              body: fixture("github", "contents_cabal_manifest.json"),
              headers: json_header
            )
        end

        it "fetches the nested path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(
              %w(cabal.project src/s3/cabal.project src/s3/src/s3/cabal.project)
            )
        end
      end
    end

    context "that is not fetchable" do
      before do
        stub_request(:get, url + "src/s3/cabal.project?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 404, headers: json_header)
        stub_request(:get, url + "src/s3?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 404, headers: json_header)
        stub_request(:get, url + "src?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 404, headers: json_header)
      end

      it "raises a PathDependenciesNotReachable error" do
        expect { file_fetcher_instance.files }.
          to raise_error(Dependabot::PathDependenciesNotReachable) do |error|
            expect(error.dependencies).to eq(["src/s3/cabal.project"])
          end
      end

      context "for a replacement source" do
        let(:parent_fixture) do
          fixture("github", "contents_cabal_manifest_replacement_path.json")
        end

        it "raises a PathDependenciesNotReachable error" do
          expect { file_fetcher_instance.files }.
            to raise_error(Dependabot::PathDependenciesNotReachable) do |error|
              expect(error.dependencies).to eq(["src/s3/cabal.project"])
            end
        end
      end

      context "when a git source is also specified" do
        let(:parent_fixture) do
          fixture("github", "contents_cabal_manifest_path_deps_alt_source.json")
        end

        before do
          stub_request(:get, url + "gen/photoslibrary1/cabal.project?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(status: 404, headers: json_header)
          stub_request(:get, url + "gen/photoslibrary1?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(status: 404, headers: json_header)
          stub_request(:get, url + "gen?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(status: 404, headers: json_header)
        end

        it "ignores that it can't fetch the path dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project))
        end
      end
    end
  end

  context "with a workspace dependency" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_without_lockfile.json"),
          headers: json_header
        )
      stub_request(:get, url + "cabal.project?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 200, body: parent_fixture, headers: json_header)
    end
    let(:parent_fixture) do
      fixture("github", "contents_cabal_manifest_workspace_root.json")
    end

    context "that is fetchable" do
      before do
        stub_request(:get, url + "lib/sub_crate/cabal.project?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: child_fixture, headers: json_header)
      end
      let(:child_fixture) do
        fixture("github", "contents_cabal_manifest_workspace_child.json")
      end

      it "fetches the workspace dependency's cabal.project" do
        expect(file_fetcher_instance.files.map(&:name)).
          to match_array(%w(cabal.project lib/sub_crate/cabal.project))
      end

      context "and specifies the dependency implicitly" do
        let(:parent_fixture) do
          fixture("github", "contents_cabal_manifest_workspace_implicit.json")
        end
        before do
          stub_request(:get, url + "src/s3/cabal.project?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(status: 200, body: child_fixture, headers: json_header)
        end

        it "fetches the workspace dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project src/s3/cabal.project))
          expect(file_fetcher_instance.files.map(&:support_file?)).
            to match_array([false, false])
        end
      end

      context "and specifies the dependency as a path dependency, too" do
        let(:parent_fixture) do
          fixture(
            "github",
            "contents_cabal_manifest_workspace_and_path_root.json"
          )
        end

        it "fetches the workspace dependency's cabal.project" do
          expect(file_fetcher_instance.files.map(&:name)).
            to match_array(%w(cabal.project lib/sub_crate/cabal.project))
          expect(file_fetcher_instance.files.map(&:support_file?)).
            to match_array([false, false])
        end
      end
    end

    context "that is not fetchable" do
      before do
        stub_request(:get, url + "lib/sub_crate/cabal.project?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 404, headers: json_header)
      end

      it "raises a DependencyFileNotFound error" do
        expect { file_fetcher_instance.files }.
          to raise_error(Dependabot::DependencyFileNotFound)
      end
    end

    context "that specifies a directory of packages" do
      let(:parent_fixture) do
        fixture("github", "contents_cabal_manifest_workspace_root_glob.json")
      end
      let(:child_fixture) do
        fixture("github", "contents_cabal_manifest_workspace_child.json")
      end
      let(:child_fixture2) do
        # This fixture also requires the first child as a path dependency,
        # so we're testing whether the first child gets fetched twice here, as
        # well as whether the second child gets fetched.
        fixture("github", "contents_cabal_manifest_workspace_child2.json")
      end

      before do
        stub_request(:get, url + "packages?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(
            status: 200,
            body: fixture("github", "contents_cabal_packages.json"),
            headers: json_header
          )
        stub_request(:get, url + "packages/sub_crate/cabal.project?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: child_fixture, headers: json_header)
        stub_request(:get, url + "packages/sub_crate2/cabal.project?ref=sha").
          with(headers: { "Authorization" => "token token" }).
          to_return(status: 200, body: child_fixture2, headers: json_header)
      end

      it "fetches the workspace dependency's cabal.project" do
        expect(file_fetcher_instance.files.map(&:name)).
          to match_array(
            %w(cabal.project
               packages/sub_crate/cabal.project
               packages/sub_crate2/cabal.project)
          )
        expect(file_fetcher_instance.files.map(&:type).uniq).
          to eq(["file"])
      end

      context "with a glob that excludes some directories" do
        let(:parent_fixture) do
          fixture(
            "github",
            "contents_cabal_manifest_workspace_root_partial_glob.json"
          )
        end
        before do
          stub_request(:get, url + "packages?ref=sha").
            with(headers: { "Authorization" => "token token" }).
            to_return(
              status: 200,
              body: fixture("github", "contents_cabal_packages_extra.json"),
              headers: json_header
            )
        end
      end
    end
  end

  context "with a cabal.project that is unparseable" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_with_lockfile.json"),
          headers: json_header
        )
      stub_request(:get, url + "cabal.project?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_cabal_manifest_unparseable.json"),
          headers: json_header
        )
    end

    it "raises a DependencyFileNotFound error" do
      expect { file_fetcher_instance.files }.
        to raise_error(Dependabot::DependencyFileNotParseable)
    end
  end

  context "without a cabal.project" do
    before do
      stub_request(:get, url + "?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(
          status: 200,
          body: fixture("github", "contents_python.json"),
          headers: json_header
        )
      stub_request(:get, url + "cabal.project?ref=sha").
        with(headers: { "Authorization" => "token token" }).
        to_return(status: 404, headers: json_header)
    end

    it "raises a DependencyFileNotFound error" do
      expect { file_fetcher_instance.files }.
        to raise_error(Dependabot::DependencyFileNotFound)
    end
  end
end
