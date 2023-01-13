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

require 'socket'
require 'yaml'
require 'json'
require 'net/http'

require_relative '../command'
require_relative '../collector'

module Hunter
  module Commands
    class SendPayload < Command
      include Hunter::Collector

      def run
        host = @options.server || Config.target_host
        port = @options.port || Config.port.to_s

        raise "No target_host provided!" if !host
        raise "No port provided!" if !port

        #uri = URI::HTTPS.build(host: host, port: port)

        #http = Net::HTTP.new(uri.host, uri.port)
        #request = Net::HTTP::Post.new(
        #  uri,
        #  'Content-Type' => 'application/json'
        #)

        data = prepare_payload
        socket = UDPSocket.new
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)
        socket.send(data.to_json, 0, Config.broadcast_address, port)
        #request.body = data.to_json

        
        
        #begin
        #  response = http.request(request)
        #  response.value
        #  puts "Successful transmission"
        #rescue Errno::ECONNREFUSED => e
        #  puts "The server is unavailable"
        #  puts e.message
        #rescue Net::HTTPServerException => e
        #  if response.code == "401"
        #    raise "Authentication key mismatch"
        #  else
        #    raise "Unknown HTTP error"
        #  end
        #end
      end

      private

      def prepare_payload
        auth_key = @options.auth || Config.auth_key.to_s

        syshostid = `hostid`.chomp
        hostid = begin
                    File.read('/proc/cmdline').split.map do |a|
                      a.split('=')
                    end.select { |a| a.length == 2}.to_h
                    sysinfo['SYSUUID'] || syshostid
                  rescue
                    syshostid
                  end

        payload_file = @options.file || Config.payload_file
        if payload_file && File.file?(payload_file)
          file_content = File.read(payload_file)
        else
          file_content = Collector.collect.to_yaml
        end

        hostname = Socket.gethostname

        {
          hostid: hostid,
          hostname: hostname,
          file_content: file_content,
          label: @options.label,
          prefix: @options.prefix,
          groups: @options.groups,
          auth_key: auth_key
        }
      end
    end
  end
end
