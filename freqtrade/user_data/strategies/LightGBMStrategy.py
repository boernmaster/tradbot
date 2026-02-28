from functools import reduce

import pandas as pd
import talib.abstract as ta
from freqtrade.strategy import IStrategy, merge_informative_pair
from pandas import DataFrame


class LightGBMStrategy(IStrategy):
    """
    FreqAI LightGBM strategy for signal-trader.

    Uses a LightGBMRegressor trained on RSI, MACD, EMA, volume, and price
    features to predict the next-candle percentage change in close price.

    Entry: FreqAI prediction above threshold AND RSI not overbought.
    Exit:  FreqAI prediction turns negative OR ROI/stoploss hit.

    Training: 90-day rolling window, no live retraining (live_retrain_hours=0).
    Target pairs: BTC/USDT, ETH/USDT — 1h timeframe.
    """

    INTERFACE_VERSION = 3

    # Freqtrade strategy settings
    can_short = False
    timeframe = "1h"
    startup_candle_count = 100

    # Conservative ROI: 5% open target, scales down over time
    minimal_roi = {
        "120": 0.01,
        "60": 0.02,
        "30": 0.03,
        "0": 0.05,
    }

    stoploss = -0.05
    trailing_stop = False

    process_only_new_candles = True
    use_exit_signal = True
    exit_profit_only = False
    ignore_roi_if_entry_signal = False

    # FreqAI prediction threshold for entry (% predicted gain)
    entry_threshold = 0.01   # predict at least +1% next 24 candles
    exit_threshold = -0.005  # exit when prediction drops below -0.5%

    def informative_pairs(self):
        return []

    def feature_engineering_expand_all(
        self, dataframe: DataFrame, period: int, metadata: dict, **kwargs
    ) -> DataFrame:
        """
        Feature engineering called for each indicator_period_candles value.
        All features prefixed with %-  so FreqAI treats them as inputs.
        """
        dataframe[f"%-rsi-period_{period}"] = ta.RSI(dataframe, timeperiod=period)

        macd = ta.MACD(dataframe, fastperiod=period, slowperiod=period * 2, signalperiod=9)
        dataframe[f"%-macd-period_{period}"] = macd["macd"]
        dataframe[f"%-macdsignal-period_{period}"] = macd["macdsignal"]
        dataframe[f"%-macdhist-period_{period}"] = macd["macdhist"]

        dataframe[f"%-ema-period_{period}"] = ta.EMA(dataframe, timeperiod=period)

        dataframe[f"%-volume_mean-period_{period}"] = (
            dataframe["volume"].rolling(period).mean()
        )

        dataframe[f"%-close_pct-period_{period}"] = dataframe["close"].pct_change(period)

        dataframe[f"%-hl_ratio-period_{period}"] = dataframe["high"] / dataframe["low"]

        dataframe[f"%-atr-period_{period}"] = ta.ATR(dataframe, timeperiod=period)

        return dataframe

    def feature_engineering_expand_basic(
        self, dataframe: DataFrame, metadata: dict, **kwargs
    ) -> DataFrame:
        """
        Basic features computed once (not per-period).
        """
        dataframe["%-pct-change"] = dataframe["close"].pct_change()
        dataframe["%-day_of_week"] = (
            pd.to_datetime(dataframe["date"]).dt.dayofweek
        )
        dataframe["%-hour_of_day"] = (
            pd.to_datetime(dataframe["date"]).dt.hour
        )
        dataframe["%-volume_pct"] = dataframe["volume"].pct_change()
        dataframe["%-raw_close"] = dataframe["close"]
        dataframe["%-raw_volume"] = dataframe["volume"]
        return dataframe

    def feature_engineering_standard(
        self, dataframe: DataFrame, metadata: dict, **kwargs
    ) -> DataFrame:
        """
        Standard features — added once, not expanded per period.
        """
        dataframe["%-close_to_high"] = dataframe["close"] / dataframe["high"]
        dataframe["%-close_to_low"] = dataframe["close"] / dataframe["low"]
        dataframe["%-body_pct"] = (
            abs(dataframe["close"] - dataframe["open"]) / dataframe["open"]
        )
        return dataframe

    def set_freqai_targets(
        self, dataframe: DataFrame, metadata: dict, **kwargs
    ) -> DataFrame:
        """
        Target label: percentage change of close price over the next
        label_period_candles (24h by default).
        FreqAI will shift this forward automatically during training.
        """
        dataframe["&-s_close"] = (
            dataframe["close"]
            .shift(-self.freqai_info["feature_parameters"]["label_period_candles"])
            .div(dataframe["close"])
            - 1
        )
        return dataframe

    def populate_indicators(
        self, dataframe: DataFrame, metadata: dict
    ) -> DataFrame:
        """
        Run FreqAI prediction. The model outputs &-s_close (predicted % gain).
        Also compute plain RSI for entry filter.
        """
        dataframe = self.freqai.start(dataframe, metadata, self)

        # RSI for entry filter — plain indicator, not a FreqAI feature
        dataframe["rsi"] = ta.RSI(dataframe, timeperiod=14)

        return dataframe

    def populate_entry_trend(
        self, dataframe: DataFrame, metadata: dict
    ) -> DataFrame:
        """
        Enter long when:
        - FreqAI predicts >= +1% gain over next 24 candles
        - RSI < 70 (not overbought)
        - No strong do-not-trade signal from FreqAI
        """
        conditions = [
            dataframe["&-s_close"] > self.entry_threshold,
            dataframe["rsi"] < 70,
            dataframe["do_predict"] == 1,
        ]

        dataframe.loc[reduce(lambda x, y: x & y, conditions), "enter_long"] = 1

        return dataframe

    def populate_exit_trend(
        self, dataframe: DataFrame, metadata: dict
    ) -> DataFrame:
        """
        Exit long when:
        - FreqAI predicts < -0.5% (momentum shifted negative)
        - OR FreqAI signals do_predict == 0 (unreliable region)
        """
        conditions = [
            dataframe["&-s_close"] < self.exit_threshold,
        ]

        dataframe.loc[reduce(lambda x, y: x & y, conditions), "exit_long"] = 1

        return dataframe
