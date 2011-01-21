
require 'ruote-amqp'


module RuoteAMQP

  #
  # = AMQP Receiver
  #
  # Used in conjunction with the RuoteAMQP::Participant, the WorkitemListener
  # subscribes to a specific direct exchange and monitors for
  # incoming workitems. It expects workitems to arrive serialized as
  # JSON.
  #
  # == Configuration
  #
  # AMQP configuration is handled by directly manipulating the values of
  # the +AMQP.settings+ hash, as provided by the AMQP gem. No
  # defaults are set by the listener. The only +option+ parsed by
  # the initializer of the workitem listener is the +queue+ key (Hash
  # expected). If no +queue+ key is set, the listener will subscribe
  # to the +ruote_workitems+ direct exchange for workitems, otherwise it will
  # subscribe to the direct exchange provided.
  #
  # == Usage
  #
  # Register the engine or storage with the listener:
  #
  #   RuoteAMQP::Receiver.new( engine_or_storage )
  #
  # The workitem listener leverages the asynchronous nature of the amqp gem,
  # so no timers are setup when initialized.
  #
  # == Options
  #
  # :queue and :launchitems
  #
  # See the RuoteAMQP::Participant docs for information on sending
  # workitems out to remote participants, and have them send replies
  # to the correct direct exchange specified in the workitem
  # attributes.
  #
  class Receiver < Ruote::Receiver

    attr_reader :queue

    # Starts a new Receiver
    #
    # Two arguments for this method.
    #
    # The first oone should be a Ruote::Engine, a Ruote::Storage or
    # a Ruote::Worker instance.
    #
    # The second one is a hash for options. There are two known options :
    #
    # :queue for setting the queue on which to listen (defaults to
    # 'ruote_workitems').
    #
    # The :launchitems option :
    #
    #   :launchitems => true
    #     # the receiver accepts workitems and launchitems
    #   :launchitems => false
    #     # the receiver only accepts workitems
    #   :launchitems => :only
    #     # the receiver only accepts launchitems
    #
    def initialize( engine_or_storage, opts = {} )

      super( engine_or_storage )

      @launchitems = opts[:launchitems]

      @queue = 'ruote_workitems'
      @queue = 'ruote_launchitems' if @launchitems == :only
      @queue = opts[:queue] if opts[:queue]

      RuoteAMQP.start!

      MQ.queue( @queue ).unsubscribe # taking over...
      sleep 0.3

      MQ.queue( @queue, :durable => true ).subscribe do |message|
        if AMQP.closing?
          # do nothing, we're going down
        else
          handle( message )
        end
      end
    end

    def stop

      RuoteAMQP.stop!
    end

    private

    def handle( msg )

      item = Rufus::Json.decode( msg ) rescue nil

      return unless item.is_a?(Hash)

      not_li = ! item.has_key?('definition')

      return if @launchitems == :only && not_li
      return unless @launchitems || not_li

      if not_li
        error = item['fields']['__error__'] rescue nil
        if error
          handle_error( item )
        else
          receive( item ) # workitem resumes in its process instance
        end
      else
        launch( item ) # new process instance launch
      end
    end

    class RemoteErrorClassProxy < Struct.new(:original_name)
      def to_s; name; end
      def name
        "(Remote) #{original_name}"
      end
    end

    class RemoteError < Struct.new(:name, :message, :backtrace)
      def class
        @class_proxy ||= RemoteErrorClassProxy.new(name)
      end
    end

    def handle_error(workitem)
      fields = workitem['fields']
      class_name = fields['__error_class__'] || 'DispatchError'
      exception = RemoteError.new( class_name, fields['__error__'], fields['__backtrace__'] )

      @context.error_handler.action_handle('receive', workitem['fei'], exception)
    end

    def launch( hash )

      super(hash['definition'], hash['fields'] || {}, hash['variables'] || {})
    end
  end
end

