# #==============================================================================
# Copyright (C) 2022-present Alces Flight Ltd.
#
# This file is part of Flight Hunter.
#
# This program and the accompanying materials are made available under
# the terms of the Eclipse Public License 2.0 which is available at
# <https://www.eclipse.org/legal/epl-2.0>, or alternative license
# terms made available by Alces Flight Ltd - please direct inquiries
# about licensing to licensing@alces-flight.com.
#
# Flight Hunter is distributed in the hope that it will be useful, but
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR
# IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS
# OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A
# PARTICULAR PURPOSE. See the Eclipse Public License 2.0 for more
# details.
#
# You should have received a copy of the Eclipse Public License 2.0
# along with Flight Hunter. If not, see:
#
#  https://opensource.org/licenses/EPL-2.0
#
# For more information on Flight Hunter, please visit:
# https://github.com/openflighthpc/flight-hunter
#==============================================================================
require 'tty-prompt'

require_relative '../command'
require_relative '../config'

module Hunter
  module Commands
    class Parse < Command
      def run
        @buffer = NodeList.load(Config.node_buffer)
        raise "No nodes in buffer" if @buffer.nodes.empty?
        @parsed = NodeList.load(Config.node_list)

        if @options.start && !/\A\d+\z/.match(@options.start)
          raise "Please provide a valid positive integer value for `--start`"
        end

        # Initialize label counts
        @label_increments = {}
        @used_strings = [].tap do |a|
          a << @parsed.nodes.map(&:label)
          a.flatten!.uniq!
        end

        final = 
          case @options.auto
          when true
            automatic_parse
          when false
            manual_parse
          end

        existing = @parsed.nodes.select { |old| final.any? { |n| old.id == n.id } }
        @parsed.delete(existing)
        @parsed.nodes.concat(final)
        @buffer.delete(final)

        if final.any? && @parsed.save && @buffer.save
          puts "Nodes saved to parsed node list:"

          Table.from_nodes(final).emit
        end
      end

      private

      def automatic_parse
        duplicates = @buffer.nodes.group_by { |n| n.presets[:label] }
                                  .reject { |k, v| k.nil? }
                                  .any? { |k, v| v.count > 1 }
        if duplicates
          raise "Duplicate preset labels in buffer list. Please resolve any duplicates before continuing."
        end

        existing = @parsed.nodes.select { |pn| @buffer.nodes.any? { |bn| pn.id == bn.id } }

        if !@options.allow_existing && existing.any?
          raise "The following IDs already exist in the parsed list:\n"\
                "#{existing.map(&:id).join("\n")}"
        end

        @buffer.nodes.each do |node|
          prefix = node.presets[:prefix] || @options.prefix
          if node.presets[:label]
            label = node.presets[:label]
          elsif prefix && !@options.start
            raise "Please provide a valid positive integer value for `--start`"
          elsif prefix && @options.start
            loop do
              label = generate_label(prefix)
              
              break unless label_exists?(label) && @options.skip_used_index
            end
          else
            label = node.hostname
          end

          if label_exists?(label)
            raise "Automatically generated label '#{label}' already exists."
          end

          @used_strings << label

          node.label = label
        end

        @buffer.nodes
      end

      def label_exists?(label)
        @used_strings.any? { |n| n == label }
      end

      def generate_label(prefix)
        start = @options.start

        @label_increments[prefix] ||= { count: 0 }
        iteration = start.to_i + @label_increments[prefix][:count]
        padding = '0' * [(start.length - iteration.to_s.length), 0].max
        count = padding + iteration.to_s

        @label_increments[prefix][:count] += 1
        return prefix + count
      end

      def manual_parse
        # Convert node objects to a hash that TTYPrompt can utilise.
        # Returns a hash of the form:
        # { String => Node, ... }
        choices = to_choices(@buffer.nodes)

        # Initialize which nodes should be preselected.
        # This is used to 'remember' which nodes were selected on each
        # subsequent re-render of the multi-select.
        defaults = []

        @continue = true

        while @continue
          answers = prompt.ordered_multi_select(
            "Select nodes:",
            choices,
            quiet: true,
            default: defaults,
            help: "(Scroll for more nodes)",
            show_help: :start,
            per_page: 10,
            edit_labels: true,
            original: @original
          )

          # If return value is a hash, the select has been intentionally aborted
          # early, so that we can mutate the frozen state. If it's anything
          # else, the select has *probably* returned successfully, and we can
          # end the while loop.
          if !answers.is_a?(Hash)
            @continue = false
            next
          end

          # Convert immutable choice objects to a mutable array object.
          # We convert it to an array instead of a hash because we need to
          # maintain the order of the choices. While hashes in Ruby *do*
          # have a deterministic order, they aren't meant to be be used that
          # way, and may not remain that way forever.
          choices = answers[:choices].map { |c| [c.name, c.value] }.reduce([], :<<)

          # While we have the original choice objects in hand, take the
          # opportunity to initialize the @original array. This is only run
          # on the first iteration of the loop, thanks to `||=`.
          #
          # This implementation prevents us from having to extend/monkey-patch
          # the TTY::Prompt::Choice class to make it mutable.
          @original ||= answers[:choices].dup

          # Initialize array of labels already in used for input validation
          reserved = []

          # Labels from nodes that already exist
          @parsed.nodes.each { |n| reserved << n.label }

          # Labels from nodes that are currently selected in the parse menu
          choices.each { |c| reserved << c[1].label }

          # Pre-generate the label, if possible
          prefill = answers[:active_choice].value.yield_self do |node|
            prefix = node.presets[:prefix] || @options.prefix
            if node.presets[:label]
              node.presets[:label]
            elsif prefix && !@options.start
              prefix
            elsif prefix && @options.start
              loop do
                label = generate_label(prefix)

                break label unless label_exists?(label) && @options.skip_used_index
              end
            else
              node.hostname
            end
          end

          # Ask the user for a label
          name = prompt.ask("Choose label:", quiet: true, value: prefill) do |q|
            q.validate ->(input) { !reserved.include?(input) }, "Label already exists"
          end.to_s.strip

          @used_strings << name

          name = name == '' ? answers[:active_choice].value.hostname : name

          # Set the label of the node belonging to the mutating choice
          # to be the label that the user has entered
          new_node = answers[:active_choice].value.tap do |n|
            n.label = name
          end

          # Update the name of the mutating choice to reflect the label change
          new_key = ["#{answers[:active_choice]} (#{name})", new_node]

          # Replace old choice array with new one, maintaining position,
          # then convert to hash so that multi-select will accept it
          choices = choices.map do |c|
            c[0] == answers[:active_choice].name ? Hash[*new_key] : Hash[*c]
          end.reduce({}, :merge)

          # Add new name to defaults array so that the re-rendered multi-select
          # can maintain which choices were selected before.
          defaults << new_key[0]
        end

        answers
      end

      def to_choices(nodes)
        nodes.map do |n|
          name = [n.hostname.to_s, n.ip].reject(&:empty?).join(" - ")
          { "#{name}" => n }
        end.reduce({}, :merge)
      end

      def prompt
        @prompt ||= TTY::Prompt.new(help_color: :yellow)
      end
    end
  end
end
