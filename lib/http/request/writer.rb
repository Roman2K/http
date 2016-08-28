# frozen_string_literal: true
require "http/headers"

module HTTP
  class Request
    class Writer
      # CRLF is the universal HTTP delimiter
      CRLF = "\r\n".freeze

      # Chunked data termintaor.
      ZERO = "0".freeze

      # Chunked transfer encoding
      CHUNKED = "chunked".freeze

      # End of a chunked transfer
      CHUNKED_END = "#{ZERO}#{CRLF}#{CRLF}".freeze

      def initialize(socket, body, headers, headline)
        @body           = body
        @socket         = socket
        @headers        = headers
        @request_header = [headline]
        @request_sender = request_sender
      end

      # Adds headers to the request header from the headers array
      def add_headers
        @headers.each do |field, value|
          @request_header << "#{field}: #{value}"
        end
      end

      # Stream the request to a socket
      def stream
        add_headers
        add_body_type_headers
        send_request
      end

      # Send headers needed to connect through proxy
      def connect_through_proxy
        add_headers
        write(join_headers)
      end

      # Adds the headers to the header array for the given request body we are working
      # with
      def add_body_type_headers
        if @body.is_a?(String) && !@headers[Headers::CONTENT_LENGTH]
          @request_header << "#{Headers::CONTENT_LENGTH}: #{@body.bytesize}"
        elsif @body.nil? && !@headers[Headers::CONTENT_LENGTH]
          @request_header << "#{Headers::CONTENT_LENGTH}: 0"
        end
      end

      # Joins the headers specified in the request into a correctly formatted
      # http request header string
      def join_headers
        # join the headers array with crlfs, stick two on the end because
        # that ends the request header
        @request_header.join(CRLF) + CRLF * 2
      end

      def send_request
        @request_sender.call
      end

      private

      def write(data)
        until data.empty?
          length = @socket.write(data)
          break unless data.bytesize > length
          data = data.byteslice(length..-1)
        end
      end

      def request_sender
        headers = join_headers

        # It's important to send the request in a single write call when
        # possible in order to play nicely with Nagle's algorithm. Making
        # two writes in a row triggers a pathological case where Nagle is
        # expecting a third write that never happens.
        if @body.nil?
          method :send_nil
        elsif @body.is_a? String
          method :send_string
        elsif @body.respond_to? :each
          if enc = @headers[Headers::TRANSFER_ENCODING]
            if enc != CHUNKED
              raise RequestError, "unsupported transfer encoding"
            end
            method :send_enum_chunked
          else
            raise RequestError, "invalid transfer encoding for enumerable body"
          end
        else
          raise RequestError, "body of wrong type: #{@body.class}"
        end
      end

      def send_nil
        write(join_headers)
      end

      def send_string
        write(join_headers << @body)
      end

      def send_enum_chunked
        write(join_headers)
        @body.each do |chunk|
          write(chunk.bytesize.to_s(16) << CRLF << chunk << CRLF)
        end
        write(CHUNKED_END)
      end
    end
  end
end
