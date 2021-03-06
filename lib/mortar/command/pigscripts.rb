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

require "mortar/command/base"

# list available pigscripts
#
class Mortar::Command::PigScripts < Mortar::Command::Base
    
  # pigscripts
  #
  # Display the available set of pigscripts
  def index
    # validation
    validate_arguments!
    if project.pigscripts.any?
      styled_header("pigscripts")
      styled_array(project.pigscripts.collect{|k,v| v.executable_path}.sort)
    else
      display("You have no pigscripts.")
    end
  end

end
