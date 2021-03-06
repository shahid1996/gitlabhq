# frozen_string_literal: true

require 'fast_spec_helper'
require 'rspec-parameterized'
require 'webmock/rspec'

require 'gitlab/danger/helper'

describe Gitlab::Danger::Helper do
  using RSpec::Parameterized::TableSyntax

  class FakeDanger
    include Gitlab::Danger::Helper

    attr_reader :git

    def initialize(git:)
      @git = git
    end
  end

  let(:teammate_json) do
    <<~JSON
    [
      {
        "username": "in-gitlab-ce",
        "name": "CE maintainer",
        "projects":{ "gitlab-ce": "maintainer backend" }
      },
      {
        "username": "in-gitlab-ee",
        "name": "EE reviewer",
        "projects":{ "gitlab-ee": "reviewer frontend" }
      }
    ]
    JSON
  end

  let(:ce_teammate_matcher) do
    satisfy do |teammate|
      teammate.username == 'in-gitlab-ce' &&
        teammate.name == 'CE maintainer' &&
        teammate.projects == { 'gitlab-ce' => 'maintainer backend' }
    end
  end

  let(:ee_teammate_matcher) do
    satisfy do |teammate|
      teammate.username == 'in-gitlab-ee' &&
        teammate.name == 'EE reviewer' &&
        teammate.projects == { 'gitlab-ee' => 'reviewer frontend' }
    end
  end

  let(:fake_git) { double('fake-git') }

  subject(:helper) { FakeDanger.new(git: fake_git) }

  describe '#all_changed_files' do
    subject { helper.all_changed_files }

    it 'interprets a list of changes from the danger git plugin' do
      expect(fake_git).to receive(:added_files) { %w[a b c.old] }
      expect(fake_git).to receive(:modified_files) { %w[d e] }
      expect(fake_git)
        .to receive(:renamed_files)
        .at_least(:once)
        .and_return([{ before: 'c.old', after: 'c.new' }])

      is_expected.to contain_exactly('a', 'b', 'c.new', 'd', 'e')
    end
  end

  describe '#ee?' do
    subject { helper.ee? }

    it 'returns true if CI_PROJECT_NAME if set to gitlab-ee' do
      stub_env('CI_PROJECT_NAME', 'gitlab-ee')
      expect(File).not_to receive(:exist?)

      is_expected.to be_truthy
    end

    it 'delegates to CHANGELOG-EE.md existence if CI_PROJECT_NAME is set to something else' do
      stub_env('CI_PROJECT_NAME', 'something else')
      expect(File).to receive(:exist?).with('../../CHANGELOG-EE.md') { true }

      is_expected.to be_truthy
    end

    it 'returns true if CHANGELOG-EE.md exists' do
      stub_env('CI_PROJECT_NAME', nil)
      expect(File).to receive(:exist?).with('../../CHANGELOG-EE.md') { true }

      is_expected.to be_truthy
    end

    it "returns false if CHANGELOG-EE.md doesn't exist" do
      stub_env('CI_PROJECT_NAME', nil)
      expect(File).to receive(:exist?).with('../../CHANGELOG-EE.md') { false }

      is_expected.to be_falsy
    end
  end

  describe '#project_name' do
    subject { helper.project_name }

    it 'returns gitlab-ee if ee? returns true' do
      expect(helper).to receive(:ee?) { true }

      is_expected.to eq('gitlab-ee')
    end

    it 'returns gitlab-ce if ee? returns false' do
      expect(helper).to receive(:ee?) { false }

      is_expected.to eq('gitlab-ce')
    end
  end

  describe '#team' do
    subject(:team) { helper.team }

    context 'HTTP failure' do
      before do
        WebMock
          .stub_request(:get, 'https://about.gitlab.com/roulette.json')
          .to_return(status: 404)
      end

      it 'raises a pretty error' do
        expect { team }.to raise_error(/Failed to read/)
      end
    end

    context 'JSON failure' do
      before do
        WebMock
          .stub_request(:get, 'https://about.gitlab.com/roulette.json')
          .to_return(body: 'INVALID JSON')
      end

      it 'raises a pretty error' do
        expect { team }.to raise_error(/Failed to parse/)
      end
    end

    context 'success' do
      before do
        WebMock
          .stub_request(:get, 'https://about.gitlab.com/roulette.json')
          .to_return(body: teammate_json)
      end

      it 'returns an array of teammates' do
        is_expected.to contain_exactly(ce_teammate_matcher, ee_teammate_matcher)
      end

      it 'memoizes the result' do
        expect(team.object_id).to eq(helper.team.object_id)
      end
    end
  end

  describe '#project_team' do
    subject { helper.project_team }

    before do
      WebMock
        .stub_request(:get, 'https://about.gitlab.com/roulette.json')
        .to_return(body: teammate_json)
    end

    it 'filters team by project_name' do
      expect(helper)
        .to receive(:project_name)
        .at_least(:once)
        .and_return('gitlab-ce')

      is_expected.to contain_exactly(ce_teammate_matcher)
    end
  end

  describe '#changes_by_category' do
    it 'categorizes changed files' do
      expect(fake_git).to receive(:added_files) { %w[foo foo.md foo.rb foo.js db/foo qa/foo] }
      allow(fake_git).to receive(:modified_files) { [] }
      allow(fake_git).to receive(:renamed_files) { [] }

      expect(helper.changes_by_category).to eq(
        backend: %w[foo.rb],
        database: %w[db/foo],
        docs: %w[foo.md],
        frontend: %w[foo.js],
        qa: %w[qa/foo],
        unknown: %w[foo]
      )
    end
  end

  describe '#category_for_file' do
    where(:path, :expected_category) do
      'doc/foo'         | :docs
      'CONTRIBUTING.md' | :docs
      'LICENSE'         | :docs
      'MAINTENANCE.md'  | :docs
      'PHILOSOPHY.md'   | :docs
      'PROCESS.md'      | :docs
      'README.md'       | :docs

      'ee/doc/foo'      | :unknown
      'ee/README'       | :unknown

      'app/assets/foo'       | :frontend
      'app/views/foo'        | :frontend
      'public/foo'           | :frontend
      'spec/javascripts/foo' | :frontend
      'vendor/assets/foo'    | :frontend
      'jest.config.js'       | :frontend
      'package.json'         | :frontend
      'yarn.lock'            | :frontend

      'ee/app/assets/foo'       | :frontend
      'ee/app/views/foo'        | :frontend
      'ee/spec/javascripts/foo' | :frontend

      'app/models/foo' | :backend
      'bin/foo'        | :backend
      'config/foo'     | :backend
      'danger/foo'     | :backend
      'lib/foo'        | :backend
      'rubocop/foo'    | :backend
      'scripts/foo'    | :backend
      'spec/foo'       | :backend
      'spec/foo/bar'   | :backend

      'ee/app/foo'      | :backend
      'ee/bin/foo'      | :backend
      'ee/spec/foo'     | :backend
      'ee/spec/foo/bar' | :backend

      'generator_templates/foo' | :backend
      'vendor/languages.yml'    | :backend
      'vendor/licenses.csv'     | :backend

      'Dangerfile'     | :backend
      'Gemfile'        | :backend
      'Gemfile.lock'   | :backend
      'Procfile'       | :backend
      'Rakefile'       | :backend
      '.gitlab-ci.yml' | :backend
      'FOO_VERSION'    | :backend

      'ee/FOO_VERSION' | :unknown

      'db/foo' | :database
      'qa/foo' | :qa

      'ee/db/foo' | :database
      'ee/qa/foo' | :qa

      'FOO'          | :unknown
      'foo'          | :unknown

      'foo/bar.rb'  | :backend
      'foo/bar.js'  | :frontend
      'foo/bar.txt' | :docs
      'foo/bar.md'  | :docs
    end

    with_them do
      subject { helper.category_for_file(path) }

      it { is_expected.to eq(expected_category) }
    end
  end

  describe '#label_for_category' do
    where(:category, :expected_label) do
      :backend   | '~backend'
      :database  | '~database'
      :docs      | '~Documentation'
      :foo       | '~foo'
      :frontend  | '~frontend'
      :qa        | '~QA'
    end

    with_them do
      subject { helper.label_for_category(category) }

      it { is_expected.to eq(expected_label) }
    end
  end
end
