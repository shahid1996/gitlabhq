module Github
  class Import

    class MergeRequest < ::MergeRequest
      self.table_name = 'merge_requests'

      self.reset_callbacks :save
      self.reset_callbacks :commit
      self.reset_callbacks :update
      self.reset_callbacks :validate
    end

    class Issue < ::Issue
      self.table_name = 'issues'

      self.reset_callbacks :save
      self.reset_callbacks :commit
      self.reset_callbacks :update
      self.reset_callbacks :validate
    end

    class Note < ::Note
      self.table_name = 'notes'

      self.reset_callbacks :save
      self.reset_callbacks :commit
      self.reset_callbacks :update
      self.reset_callbacks :validate
    end

    attr_reader :project, :repository, :repo, :options, :errors,
                :cached_label_ids, :cached_gitlab_users, :cached_user_ids

    def initialize(project, options)
      @project = project
      @repository = project.repository
      @repo = project.import_source
      @options = options
      @cached_label_ids = {}
      @cached_user_ids = {}
      @cached_gitlab_users = {}
      @errors  = []
    end

    def execute
      fetch_repository
      fetch_labels
      fetch_milestones
      fetch_pull_requests
      fetch_issues
      fetch_wiki_repository
      expire_repository_cache

      errors
    end

    private

    def fetch_repository
      begin
        project.create_repository
        project.repository.add_remote('github', "https://{options.fetch(:token)}@github.com/#{repo}.git")
        project.repository.set_remote_as_mirror('github')
        project.repository.fetch_remote('github', forced: true)
      rescue Gitlab::Shell::Error => e
        error(:project, "https://github.com/#{repo}.git", e.message)
      end
    end

    def fetch_wiki_repository
      wiki_url  = "https://{options.fetch(:token)}@github.com/#{repo}.wiki.git"
      wiki_path = "#{project.path_with_namespace}.wiki"

      unless project.wiki.repository_exists?
        gitlab_shell.import_repository(project.repository_storage_path, wiki_path, wiki_url)
      end
    rescue Gitlab::Shell::Error => e
      # GitHub error message when the wiki repo has not been created,
      # this means that repo has wiki enabled, but have no pages. So,
      # we can skip the import.
      if e.message !~ /repository not exported/
        errors(:wiki, wiki_url, e.message)
      end
    end

    def fetch_labels
      url = "/repos/#{repo}/labels"

      while url
        response = Github::Client.new(options).get(url)

        response.body.each do |raw|
          begin
            label = Github::Representation::Label.new(raw)
            next if project.labels.where(title: label.title).exists?

            project.labels.create!(title: label.title, color: label.color)
          rescue => e
            error(:label, label.url, e.message)
          end
        end

        url = response.rels[:next]
      end

      # Cache labels
      project.labels.select(:id, :title).find_each do |label|
        @cached_label_ids[label.title] = label.id
      end
    end

    def fetch_milestones
      url = "/repos/#{repo}/milestones"

      while url
        response = Github::Client.new(options).get(url, state: :all)

        response.body.each do |raw|
          begin
            milestone = Github::Representation::Milestone.new(raw)
            next if project.milestones.where(iid: milestone.iid).exists?

            project.milestones.create!(
              iid: milestone.iid,
              title: milestone.title,
              description: milestone.description,
              due_date: milestone.due_date,
              state: milestone.state,
              created_at: milestone.created_at,
              updated_at: milestone.updated_at
            )
          rescue => e
            error(:milestone, milestone.url, e.message)
          end
        end

        url = response.rels[:next]
      end
    end

    def fetch_pull_requests
      url = "/repos/#{repo}/pulls"

      while url
        response = Github::Client.new(options).get(url, state: :all, sort: :created, direction: :asc)

        response.body.each do |raw|
          pull_request  = Github::Representation::PullRequest.new(project, raw, options)
          merge_request = MergeRequest.find_or_initialize_by(iid: pull_request.iid, source_project_id: project.id)
          next unless merge_request.new_record? && pull_request.valid?

          begin
            restore_source_branch(pull_request) unless pull_request.source_branch_exists?
            restore_target_branch(pull_request) unless pull_request.target_branch_exists?

            author_id                       = user_id(pull_request.author, project.creator_id)
            merge_request.iid               = pull_request.iid
            merge_request.title             = pull_request.title
            merge_request.description       = format_description(pull_request.description, pull_request.author)
            merge_request.source_project    = pull_request.source_project
            merge_request.source_branch     = pull_request.source_branch_name
            merge_request.source_branch_sha = pull_request.source_branch_sha
            merge_request.target_project    = pull_request.target_project
            merge_request.target_branch     = pull_request.target_branch_name
            merge_request.target_branch_sha = pull_request.target_branch_sha
            merge_request.state             = pull_request.state
            merge_request.milestone_id      = milestone_id(pull_request.milestone)
            merge_request.author_id         = author_id
            merge_request.assignee_id       = user_id(pull_request.assignee)
            merge_request.created_at        = pull_request.created_at
            merge_request.updated_at        = pull_request.updated_at
            merge_request.save!(validate: false)

            merge_request.merge_request_diffs.create

            # Fetch review comments
            review_comments_url = "/repos/#{repo}/pulls/#{pull_request.iid}/comments"
            fetch_comments(merge_request, :review_comment, review_comments_url)

            # Fetch comments
            comments_url = "/repos/#{repo}/issues/#{pull_request.iid}/comments"
            fetch_comments(merge_request, :comment, comments_url)
          rescue => e
            error(:pull_request, pull_request.url, e.message)
          ensure
            clean_up_restored_branches(pull_request)
          end
        end

        url = response.rels[:next]
      end
    end

    def fetch_issues
      url = "/repos/#{repo}/issues"

      while url
        response = Github::Client.new(options).get(url, state: :all, sort: :created, direction: :asc)

        response.body.each do |raw|
          representation = Github::Representation::Issue.new(raw, options)

          begin
            # Every pull request is an issue, but not every issue
            # is a pull request. For this reason, "shared" actions
            # for both features, like manipulating assignees, labels
            # and milestones, are provided within the Issues API.
            if representation.pull_request?
              next unless representation.has_labels?

              merge_request = MergeRequest.find_by!(target_project_id: project.id, iid: representation.iid)
              merge_request.update_attribute(:label_ids, label_ids(representation.labels))
            else
              next if Issue.where(iid: representation.iid, project_id: project.id).exists?

              author_id          = user_id(representation.author, project.creator_id)
              issue              = Issue.new
              issue.iid          = representation.iid
              issue.project_id   = project.id
              issue.title        = representation.title
              issue.description  = format_description(representation.description, representation.author)
              issue.state        = representation.state
              issue.label_ids    = label_ids(representation.labels)
              issue.milestone_id = milestone_id(representation.milestone)
              issue.author_id    = author_id
              issue.assignee_id  = user_id(representation.assignee)
              issue.created_at   = representation.created_at
              issue.updated_at   = representation.updated_at
              issue.save!(validate: false)

              # Fetch comments
              if representation.has_comments?
                comments_url = "/repos/#{repo}/issues/#{issue.iid}/comments"
                fetch_comments(issue, :comment, comments_url)
              end
            end
          rescue => e
            error(:issue, representation.url, e.message)
          end
        end

        url = response.rels[:next]
      end
    end

    def fetch_comments(noteable, type, url)
      while url
        comments = Github::Client.new(options).get(url)

        ActiveRecord::Base.no_touching do
          comments.body.each do |raw|
            begin
              representation  = Github::Representation::Comment.new(raw, options)
              author_id       = user_id(representation.author, project.creator_id)

              note            = Note.new
              note.project_id = project.id
              note.noteable   = noteable
              note.note       = format_description(representation.note, representation.author)
              note.commit_id  = representation.commit_id
              note.line_code  = representation.line_code
              note.author_id  = author_id
              note.type       = representation.type
              note.created_at = representation.created_at
              note.updated_at = representation.updated_at
              note.save!(validate: false)
            rescue => e
              error(type, representation.url, e.message)
            end
          end
        end

        url = comments.rels[:next]
      end
    end

    def fetch_releases
      url = "/repos/#{repo}/releases"

      while url
        response = Github::Client.new(options).get(url)

        response.body.each do |raw|
          representation = Github::Representation::Release.new(raw)
          next unless representation.valid?

          release = ::Release.find_or_initialize_by(project_id: project.id, tag: representation.tag)
          next unless relese.new_record?

          begin
            release.description = representation.description
            release.created_at  = representation.created_at
            release.updated_at  = representation.updated_at
            release.save!(validate: false)
          rescue => e
            error(:release, representation.url, e.message)
          end
        end

        url = response.rels[:next]
      end
    end

    def restore_source_branch(pull_request)
      repository.create_branch(pull_request.source_branch_name, pull_request.source_branch_sha)
    end

    def restore_target_branch(pull_request)
      repository.create_branch(pull_request.target_branch_name, pull_request.target_branch_sha)
    end

    def remove_branch(name)
      repository.delete_branch(name)
    rescue Rugged::ReferenceError
      errors << { type: :branch, url: nil, error: "Could not clean up restored branch: #{name}" }
    end

    def clean_up_restored_branches(pull_request)
      return if pull_request.opened?

      remove_branch(pull_request.source_branch_name) unless pull_request.source_branch_exists?
      remove_branch(pull_request.target_branch_name) unless pull_request.target_branch_exists?
    end

    def label_ids(issuable)
      issuable.map { |attrs| cached_label_ids[attrs.fetch('name')] }.compact
    end

    def milestone_id(milestone)
      return unless milestone.present?

      project.milestones.select(:id).find_by(iid: milestone.iid)&.id
    end

    def user_id(user, fallback_id = nil)
      return unless user.present?
      return cached_user_ids[user.id] if cached_user_ids.key?(user.id)

      gitlab_user_id = find_by_external_uid(user.id) || find_by_email(user.email)

      cached_gitlab_users[user.id] = gitlab_user_id.present?
      cached_user_ids[user.id] = gitlab_user_id || fallback_id
    end

    def find_by_email(email)
      return nil unless email

      ::User.find_by_any_email(email)&.id
    end

    def find_by_external_uid(id)
      return nil unless id

      identities = ::Identity.arel_table

      ::User.select(:id)
            .joins(:identities)
            .where(identities[:provider].eq(:github).and(identities[:extern_uid].eq(id)))
            .first&.id
    end

    def format_description(body, author)
      return body if cached_gitlab_users[author.id]

      "*Created by: #{author.username}*\n\n#{body}"
    end

    def expire_repository_cache
      repository.expire_content_cache
    end

    def error(type, url, message)
      errors << { type: type, url: Gitlab::UrlSanitizer.sanitize(url), error: message }
    end
  end
end
