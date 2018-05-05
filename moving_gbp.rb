# coding: utf-8

require 'jiji/model/agents/agent'
require 'date'
require 'json'
require 'logger'

class MovingGbp

  include Jiji::Model::Agents::Agent

  def self.description
    <<-STR
GBP補助的自動売買
      STR
  end

  def self.property_infos
    [
      Property.new('exec_mode',
        '動作モード("all")', "all"),
      Property.new('trade_units','取引数量', 10000)
    ]
  end

  def post_create
    @calculator = SignalCalculator.new(broker)
    @cross = Cross.new
    @mode  = create_mode(@exec_mode)

    @graph = graph_factory.create('移動平均',
      :rate, :last, ['#FF6633', '#FFAA22'])
    logger.debug "initialize"
  end

  # 次のレートを受け取る
  def next_tick(tick)
    date = tick.timestamp.to_date
    return if !@current_date.nil? && @current_date == date
    @current_date = date

    signal = @calculator.next_tick(tick)
    @cross.next_data(signal[:ma5], signal[:ma10])

    @graph << [signal[:ma5], signal[:ma10]]
    do_trade(signal)
  end

  def do_trade(signal)
    # RSIとMA5/MA10を確認
    if @cross.cross_up? && signal[:rsi] < 50
      buy(signal)
    elsif @cross.cross_down? && signal[:rsi] > 50
      sell(signal)
    end
    if (@cross.cross_up? && signal[:rsi] > 55) || (@cross.cross_down? && signal[:rsi] < 45)
      close_exist_positions
    end
    # 損失が一定額でクローズ
    if !@current_position.nil?  
      # 1枚毎の損失が1万5千円超えると切る
      if @current_position.profit_or_loss.to_i/(@trade_units.to_i/10000) < -15000
        close_exist_positions
      end
    end
  end

  def buy(signal)
    close_exist_positions
    return unless @mode.do_trade?(signal, "buy")
    result = broker.buy(:GBPJPY, @trade_units.to_i)
    @current_position = broker.positions[result.trade_opened.internal_id]
    @current_signal = signal
  end

  def sell(signal)
    close_exist_positions
    return unless @mode.do_trade?(signal, "sell")
    result = broker.sell(:GBPJPY, @trade_units.to_i)
    @current_position = broker.positions[result.trade_opened.internal_id]
    @current_signal = signal
  end

  def close_exist_positions
    return unless @current_position
    @current_position.close
    @current_position = nil
    @current_signal = nil
  end
end


# トレード結果とその時の各種指標。
# MongoDBに格納してTensorFlowの学習データにする
class TradeAndSignals

  include Mongoid::Document

  store_in collection: 'tensorflow_example_trade_and_signals'

  field :macd_difference,    type: Float # macd - macd_signal

  field :rsi,                type: Float

  field :slope_10,           type: Float # 10日移動平均線の傾き
  field :slope_25,           type: Float # 25日移動平均線の傾き
  field :slope_50,           type: Float # 50日移動平均線の傾き

  field :ma_10_estrangement, type: Float # 10日移動平均からの乖離率
  field :ma_25_estrangement, type: Float
  field :ma_50_estrangement, type: Float

  field :profit_or_loss,     type: Float
  field :sell_or_buy,        type: Symbol
  field :entered_at,         type: Time
  field :exited_at,          type: Time

  def self.create_from( signal_data, position )
    TradeAndSignals.new do |ts|
      signal_data.each do |pair|
        next if pair[0] == :ma5|| pair[0] == :ma10
        ts.send( "#{pair[0]}=".to_sym, pair[1] )
      end
      ts.profit_or_loss = position.profit_or_loss
      ts.sell_or_buy    = position.sell_or_buy
      ts.entered_at     = position.entered_at
      ts.exited_at      = position.exited_at
    end
  end
end

# シグナルを計算するクラス
class SignalCalculator

  def initialize(broker)
    @broker = broker
  end

  def next_tick(tick)
    prepare_signals(tick) unless @macd
    calculate_signals(tick[:GBPJPY])
  end

  def calculate_signals(tick)
    price = tick.bid
    macd = @macd.next_data(price)
    ma5  = @ma5.next_data(price)
    ma10 = @ma10.next_data(price)
    ma25 = @ma25.next_data(price)
    ma50 = @ma50.next_data(price)
    {
      ma5:  ma5,
      ma10: ma10,
      macd_difference: macd ? macd[:macd] - macd[:signal] : nil,
      rsi:  @rsi.next_data(price),
      slope_10: ma10 ? @ma10v.next_data(ma10) : nil,
      slope_25: ma25 ? @ma25v.next_data(ma25) : nil,
      slope_50: ma50 ? @ma50v.next_data(ma50) : nil,
      ma_10_estrangement: ma10 ? calculate_estrangement(price, ma10) : nil,
      ma_25_estrangement: ma25 ? calculate_estrangement(price, ma25) : nil,
      ma_50_estrangement: ma50 ? calculate_estrangement(price, ma50) : nil,
      price:  price
    }
  end

  def prepare_signals(tick)
    create_signals
    retrieve_rates(tick.timestamp).each do |rate|
      calculate_signals(rate.close)
    end
  end

  def create_signals
    @macd  = Signals::MACD.new
    @ma5   = Signals::MovingAverage.new(5)
    @ma10  = Signals::MovingAverage.new(10)
    @ma25  = Signals::MovingAverage.new(25)
    @ma50  = Signals::MovingAverage.new(50)
    @ma5v  = Signals::Vector.new(5)
    @ma10v = Signals::Vector.new(10)
    @ma25v = Signals::Vector.new(25)
    @ma50v = Signals::Vector.new(50)
    @rsi   = Signals::RSI.new(9)
  end

  def retrieve_rates(time)
    @broker.retrieve_rates(:GBPJPY, :fifteen_minutes, time - 60*15*60, time )
  end

  def calculate_estrangement(price, ma)
    ((BigDecimal.new(price, 10) - ma) / ma * 100).to_f
  end

end
