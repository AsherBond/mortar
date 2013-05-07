#
# Copyright 2012 Mortar Data Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "vendor/mortar/uuid"
require "mortar/helpers"
require "set"

module Mortar
  module Git
    
    class GitError < RuntimeError; end
    
    class Git
      
      #
      # core commands
      #
      
      def has_git?
        # Needs to have git version 1.7.7 or greater.  Earlier versions lack 
        # the necessary untracked option for stash.
        git_version_output, has_git = run_cmd("git --version")
        if has_git
          git_version = git_version_output.split(" ")[2]
          versions = git_version.split(".")
          is_ok_version = versions[0].to_i >= 2 ||
                          ( versions[0].to_i == 1 && versions[1].to_i >= 8 ) ||
                          ( versions[0].to_i == 1 && versions[1].to_i == 7 && versions[2].to_i >= 7)
        end
        has_git && is_ok_version
      end
      
      def ensure_has_git
        unless has_git?
          raise GitError, "git 1.7.7 or higher must be installed"
        end
      end

      def run_cmd(cmd)
        begin
          output = %x{#{cmd}}
        rescue Exception => e
          output = ""
        end
        return [output, $?.success?]
      end
      
      def has_dot_git?
        File.directory?(".git")
      end

      def git_init
        ensure_has_git
        run_cmd("git init")
      end
      
      def git(args, check_success=true, check_git_directory=true)
        ensure_has_git
        if check_git_directory && !has_dot_git?
          raise GitError, "No .git directory found"
        end
        
        flattened_args = [args].flatten.compact.join(" ")
        output = %x{ git #{flattened_args} 2>&1 }.strip
        success = $?.success?
        if check_success && (! success)
          raise GitError, "Error executing 'git #{flattened_args}':\n#{output}"
        end
        output
      end

      def push_master
        unless has_commits?
          raise GitError, "No commits found in repository.  You must do an initial commit to initialize the repository."
        end

        safe_copy(mortar_manifest_pathlist) do
          did_stash_changes = stash_working_dir("Stash for push to master")
          git('push mortar master')
        end

      end

      #
      # Create a safe temporary directory with a given list of filesystem paths (files or dirs) copied into it
      #

      def safe_copy(pathlist, &block)
        # Copy code into a temp directory so we don't confuse editors while snapshotting
        curdir = Dir.pwd
        tmpdir = Dir.mktmpdir
        FileUtils.cp_r(pathlist, tmpdir)
        Dir.chdir(tmpdir)

        if block
          yield
          FileUtils.remove_entry_secure(tmpdir)
          Dir.chdir(curdir)
        else
          return tmpdir
        end
      end

      #
      # Only snapshot filesystem paths that are in a whitelist
      #

      def mortar_manifest_pathlist(include_dot_git = true)
        ensure_valid_mortar_project_manifest()

        manifest_pathlist = File.read(".mortar-project-manifest").split("\n")
        if include_dot_git
          manifest_pathlist << ".git"
        end

        manifest_pathlist.each do |path|
          unless File.exists? path
            Helpers.error(".mortar-project-manifest includes file/dir \"#{path}\" that is not in the mortar project directory.")
          end
        end
        
        manifest_pathlist
      end

      #
      # Create a snapshot whitelist file if it doesn't already exist
      #
      def ensure_valid_mortar_project_manifest()
        if File.exists? ".mortar-project-manifest"
          File.open(".mortar-project-manifest", "r+") do |manifest|
            contents = manifest.read()
            manifest.seek(0, IO::SEEK_END)

            # `contents` in ruby 1.8.7 is array with entries of the
            # type Fixnum which isn't semantically comparable with
            # the \n char, but the ascii code 10 is
            unless (contents[-1] == "\n" or contents[-1] == 10)
              manifest.puts "" # ensure file ends with a newline
            end

            if File.directory?('controlscripts') and not contents.include?('controlscripts')
              manifest.puts "controlscripts"
            end
          end
        else
          create_mortar_project_manifest('.')
        end
      end

      #
      # Create a project manifest file
      #
      def create_mortar_project_manifest(path)
        File.open("#{path}/.mortar-project-manifest", 'w') do |manifest|
          if File.directory? "#{path}/controlscripts"
            manifest.puts "controlscripts"
          end
          if File.directory? "#{path}/fixtures"
            manifest.puts "fixtures"
          end
          manifest.puts "pigscripts"
          manifest.puts "macros"
          manifest.puts "udfs"
        end
      end
    
      #    
      # snapshot
      #

      def create_snapshot_branch
        # TODO: handle Ctrl-C in the middle
        unless has_commits?
          raise GitError, "No commits found in repository.  You must do an initial commit to initialize the repository."
        end

        # Copy code into a temp directory so we don't confuse editors while snapshotting
        curdir = Dir.pwd
        tmpdir = safe_copy(mortar_manifest_pathlist)
      
        starting_branch = current_branch
        snapshot_branch = "mortar-snapshot-#{Mortar::UUID.create_random.to_s}"

        # checkout a new branch
        git("checkout -b #{snapshot_branch}")
      
        # stage all changes (including deletes)
        git("add .")
        git("add -u .")

        # commit the changes if there are any
        if ! is_clean_working_directory?
          git("commit -m \"mortar development snapshot commit\"")
        end
      
        Dir.chdir(curdir)
        return tmpdir, snapshot_branch
      end

      def create_and_push_snapshot_branch(project)
        curdir = Dir.pwd

        # create a snapshot branch in a temporary directory
        snapshot_dir, snapshot_branch = Helpers.action("Taking code snapshot") do
          create_snapshot_branch()
        end

        Dir.chdir(snapshot_dir)
        git_ref = push_with_retry(project.remote, snapshot_branch, "Sending code snapshot to Mortar")
        FileUtils.remove_entry_secure(snapshot_dir)
        Dir.chdir(curdir)
        return git_ref
      end

      def retry_snapshot_push?
        @last_snapshot_retry_sleep_time ||= 0
        @snapshot_retry_sleep_time ||= 1

        sleep(@snapshot_retry_sleep_time)
        @last_snapshot_retry_sleep_time, @snapshot_retry_sleep_time = 
          @snapshot_retry_sleep_time, @last_snapshot_retry_sleep_time + @snapshot_retry_sleep_time

        @snapshot_push_attempts ||= 0
        @snapshot_push_attempts += 1
        @snapshot_push_attempts < 10
      end

      def mortar_mirrors_dir()
        "/tmp/mortar-git-mirrors"
      end

      def sync_gitless_project(project)
        # the project is not a git repo, so we manage a mirror directory that is a git repo

        project_dir = project.root_path
        mirror_dir = "#{mortar_mirrors_dir}/#{project.name}"

        # create and initialize mirror git repo if it doesn't already exist
        unless File.directory? mirror_dir
          unless File.directory? mortar_mirrors_dir
            FileUtils.mkdir_p mortar_mirrors_dir
          end

          # clone mortar-code repo
          remote_path = File.open(".mortar-project-remote").read.strip
          clone(remote_path, mirror_dir)

          # make an initial commit to master
          Dir.chdir(mirror_dir)
          File.open(".gitkeep", "w").close()
          git("add .")
          git("commit -m \"mortar development initial commit\"")
          git("remote add mortar #{remote_path}")
          push_with_retry("mortar", "master", "Setting up gitless Mortar project")
        end

        # pull from master and overwrite everything
        Dir.chdir(mirror_dir)
        git("fetch --all")
        git("reset --hard mortar/master")

        # wipe mirror dir and copy project files into it
        # since we fetched mortar/master earlier, the git diff will now be b/tw master and the current state
        # mortar_manifest_pathlist(false) means don't copy .git
        FileUtils.rm_rf(Dir.glob("#{mirror_dir}/*"))
        Dir.chdir(project_dir)
        FileUtils.cp_r(mortar_manifest_pathlist(false), mirror_dir)

        # update master
        Dir.chdir(mirror_dir)
        unless is_clean_working_directory?
          git("add .")
          git("add -u .") # this gets deletes
          git("commit -m \"mortar development snapshot commit\"")
        end

        # checkout snapshot branch.
        # it will permenantly keep the code in this state (as opposed to master, which will be updated)
        snapshot_branch = "mortar-snapshot-#{Mortar::UUID.create_random.to_s}"
        git("checkout -b #{snapshot_branch}")

        # push everything (master updates and snapshot branch)
        git_ref = push_with_retry("mortar", snapshot_branch, "Sending code snapshot to Mortar", true)

        git("checkout master")
        Dir.chdir(project_dir)
        return git_ref
      end

      #    
      # add
      #    

      def add(path)
        git("add #{path}")
      end

      #
      # branch
      #
      
      def branches
        git("branch")
      end
      
      def current_branch
        branches.split("\n").each do |branch_listing|
        
          # current branch will be the one that starts with *, e.g.
          #   not_my_current_branch
          # * my_current_branch
          if branch_listing =~ /^\*\s(\S*)/
            return $1
          end
        end
        raise GitError, "Unable to find current branch in list #{branches}"
      end
      
      def branch_delete(branch_name)
        git("branch -D #{branch_name}")
      end

      #
      # push
      #
      
      def push(remote_name, ref)
        git("push #{remote_name} #{ref}")
      end

      def push_all(remote_name)
        git("push #{remote_name} --all")
      end

      def push_with_retry(remote_name, branch_name, action_msg, push_all_branches = false)
        git_ref = Helpers.action(action_msg) do
          # push the code
          begin
              if push_all_branches
                push_all(remote_name)
              else
                push(remote_name, branch_name)
              end
          rescue
            retry if retry_snapshot_push?
            Helpers.error("Could not connect to github remote. Tried #{@snapshot_push_attempts.to_s} times.")
          end

          # grab the commit hash
          ref = git_ref(branch_name)
          ref
        end

        return git_ref
      end

      #
      # pull
      #

      def pull(remote_name, ref)
        git("pull #{remote_name} #{ref}")
      end


      #
      # remotes
      #

      def remotes(git_organization)
        # returns {git_remote_name => project_name}
        remotes = {}
        git("remote -v").split("\n").each do |remote|
          name, url, method = remote.split(/\s/)
          if url =~ /^git@([\w\d\.]+):#{git_organization}\/[a-zA-Z0-9]+_([\w\d-]+)\.git$$/
            remotes[name] = $2
          end
        end
        
        remotes
      end
      
      def remote_add(name, url)
        git("remote add #{name} #{url}")
      end

      #
      # rev-parse
      #
      def git_ref(refname)
        git("rev-parse --verify --quiet #{refname}")
      end

      #
      # stash
      #

      def stash_working_dir(stash_description)
        stash_output = git("stash save --include-untracked #{stash_description}")
        did_stash_changes? stash_output
      end
    
      def did_stash_changes?(stash_message)
        ! (stash_message.include? "No local changes to save")
      end

      #
      # status
      #
      
      def status
        git('status --porcelain')
      end
      
      
      def has_commits?
        # see http://stackoverflow.com/a/5492347
        %x{ git rev-parse --verify --quiet HEAD }
        $?.success?
      end

      def is_clean_working_directory?
        status.empty?
      end
    
      # see https://www.kernel.org/pub/software/scm/git/docs/git-status.html#_output
      GIT_STATUS_CODES__CONFLICT = Set.new ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
      def has_conflicts?
        def status_code(status_str)
          status_str[0,2]
        end
      
        status_codes = status.split("\n").collect{|s| status_code(s)}
        ! GIT_STATUS_CODES__CONFLICT.intersection(status_codes).empty?
      end
      
      def untracked_files
        git("ls-files -o --exclude-standard").split("\n")
      end
      
      #
      # clone
      #
      def clone(git_url, path="")
        git("clone %s \"%s\"" % [git_url, path], true, false)
      end
    end
  end
end
