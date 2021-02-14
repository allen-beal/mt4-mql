/**
 * XMT-Scalper revisited
 *
 *
 * This EA is originally based on the famous "MillionDollarPips EA". The core idea of the strategy is scalping based on a
 * reversal from a channel breakout. Over the years it has gone through multiple transformations. Today various versions with
 * different names circulate in the internet (MDP-Plus, XMT-Scalper, Assar). None of them can be used for real trading, mainly
 * due to lack of signal documentation and a significant amount of issues in the program logic.
 *
 * This version is a complete rewrite.
 *
 * Sources:
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/a1b22d0/mql4/experts/mdp#             [MillionDollarPips v2 decompiled]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/36f494e/mql4/experts/mdp#                    [MDP-Plus v2.2 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/41237e0/mql4/experts/mdp#               [XMT-Scalper v2.522 by Capella]
 *
 *
 * Changes:
 *  - removed MQL5 syntax and fixed compiler issues
 *  - added rosasurfer framework and the framework's test reporting
 *  - moved print output to the framework logger
 *  - added monitoring of PositionOpen and PositionClose events
 *  - removed obsolete functions and variables
 *  - removed obsolete order expiration, NDD and screenshot functionality
 *  - removed obsolete sending of fake orders and measuring of execution times
 *  - removed broken commission calculations
 *  - simplified input parameters
 *  - fixed input parameter validation
 *  - fixed position size calculation
 *  - fixed signal detection (new input ActiveBugs.ChannelCalculation)
 *  - fixed trade handling (new inputs ActiveBugs.TpCalculationShort and ActiveBugs.TpTrailing)
 *  - rewrote status display
 *
 *  - renamed input parameter UseDynamicVolatilityLimit => UseSpreadMultiplier
 *  - renamed input parameter VolatilityMultiplier      => SpreadMultiplier
 *  - renamed input parameter VolatilityLimit           => MinBarSize
 *  - renamed input parameter MinimumUseStopLevel       => BreakoutReversal
 *  - renamed input parameter ReverseTrades             => ReverseSignals
 */
#include <stddefines.mqh>
int   __InitFlags[] = {INIT_TIMEZONE, INIT_PIPVALUE, INIT_BUFFERED_LOG};
int __DeinitFlags[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string ___a___________________________ = "=== Entry indicator: 1=MovingAverage, 2=BollingerBands, 3=Envelopes ===";
extern int    EntryIndicator                  = 1;          // entry signal indicator for price channel calculation
extern int    IndicatorPeriods                = 3;          // entry indicator bar periods
extern double BollingerBands.Deviation        = 2;          // standard deviations
extern double Envelopes.Deviation             = 0.07;       // in percent

extern string ___b___________________________ = "=== Entry bar size conditions ================";
extern bool   UseSpreadMultiplier             = true;       // use spread multiplier or fix MinBarSize
extern double SpreadMultiplier                = 12.5;       // MinBarSize = SpreadMultiplier * avgSpread
extern double MinBarSize                      = 18;         // MinBarSize = fix size in pip

extern string ___c___________________________ = "=== Trade settings ========================";
extern int    TimeFrame                       = PERIOD_M1;  // trading timeframe
extern int    BreakoutReversal                = 0;          // breakout reversal in point (0: counter-trend trading w/o reversal)
extern int    TakeProfit                      = 10;         // TP in pip
extern int    StopLoss                        = 6;          // SL in pip
extern double TrailingStart                   = 20;         // start trailing profit from as so many points
extern int    MaxSpread                       = 30;         // max. acceptable spread in point
extern int    Slippage                        = 3;          // acceptable market order slippage in point
extern int    Magic                           = 0;          // if zero the MagicNumber is generated
extern bool   ReverseSignals                  = false;      // Buy => Sell, Sell => Buy

extern string ___d___________________________ = "=== MoneyManagement ====================";
extern bool   MoneyManagement                 = true;       // if TRUE lots are calculated dynamically, if FALSE "ManualLotsize" is used
extern double Risk                            = 2;          // percent of equity to risk for each trade
extern double ManualLotsize                   = 0.1;        // fix position size to use if "MoneyManagement" is FALSE

extern string ___e___________________________ = "=== Bugs ================================";
extern bool   Bug.ChannelCalculation          = true;       // broken calculation of signal channel high/low
extern bool   Bug.StepTrailing                = true;       // trailing in steps of TrailingStart only
extern bool   Bug.ShortTrailing               = true;       // invalid trailing condition of short positions

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>
#include <functions/JoinStrings.mqh>
#include <structs/rsf/OrderExecution.mqh>

#define SIGNAL_LONG     1
#define SIGNAL_SHORT    2


// order log
int      orders.ticket      [];
double   orders.lots        [];        // order volume > 0
int      orders.pendingType [];        // pending order type if applicable or OP_UNDEFINED (-1)
double   orders.pendingPrice[];        // pending entry limit if applicable or 0
int      orders.openType    [];        // order open type if triggered or OP_UNDEFINED (-1)
datetime orders.openTime    [];        // order open time if triggered or 0
double   orders.openPrice   [];        // order open price if triggered or 0
datetime orders.closeTime   [];        // order close time if closed or 0
double   orders.closePrice  [];        // order close price if closed or 0
double   orders.stopLoss    [];        // SL price or 0
double   orders.takeProfit  [];        // TP price or 0
double   orders.swap        [];        // order swap
double   orders.commission  [];        // order commission
double   orders.profit      [];        // order profit (gross)

// PL statistics
int      openPositions;                // number of open positions
double   openLots;                     // total open lotsize
double   openSwap;                     // total open swap
double   openCommission;               // total open commissions
double   openPl;                       // total open gross profit
double   openPlNet;                    // total open net profit

int      closedPositions;              // number of closed positions
double   closedLots;                   // total closed lotsize
double   closedSwap;                   // total closed swap
double   closedCommission;             // total closed commission
double   closedPl;                     // total closed gross profit
double   closedPlNet;                  // total closed net profit

double   totalPlNet;                   // openPlNet + closedPlNet

// other
string   orderComment = "XMT-rsf";

// cache vars to speed-up ShowStatus()
string   sUnitSize   = "";
string   sStatusInfo = "\n\n\n";
string   sIndicator  = "";
string   sCurrSpread = "-";
string   sAvgSpread  = "-";


/**
 * Initialization
 *
 * @return int - error status
 */
int onInit() {
   // validate inputs
   // EntryIndicator
   if (EntryIndicator < 1 || EntryIndicator > 3)                       return(catch("onInit(1)  invalid input parameter EntryIndicator: "+ EntryIndicator +" (must be from 1-3)", ERR_INVALID_INPUT_PARAMETER));
   // Timeframe
   if (Period() != TimeFrame)                                          return(catch("onInit(2)  invalid chart timeframe "+ PeriodDescription(Period()) +" (the EA must run on the configured timeframe "+ PeriodDescription(TimeFrame) +")", ERR_RUNTIME_ERROR));
   // BreakoutReversal
   if (LT(BreakoutReversal, MarketInfo(Symbol(), MODE_STOPLEVEL)))     return(catch("onInit(3)  invalid input parameter BreakoutReversal: "+ BreakoutReversal +" (must be larger than MODE_STOPLEVEL)", ERR_INVALID_INPUT_PARAMETER));
   // TakeProfit
   if (LT(TakeProfit*Pip, MarketInfo(Symbol(), MODE_STOPLEVEL)*Point)) return(catch("onInit(4)  invalid input parameter TakeProfit: "+ TakeProfit +" (must be larger than MODE_STOPLEVEL)", ERR_INVALID_INPUT_PARAMETER));
   // StopLoss
   if (!StopLoss)                                                      return(catch("onInit(5)  invalid input parameter StopLoss: "+ StopLoss +" (must be positive)", ERR_INVALID_INPUT_PARAMETER));
   if (LT(StopLoss*Pip, MarketInfo(Symbol(), MODE_STOPLEVEL)*Point))   return(catch("onInit(6)  invalid input parameter StopLoss: "+ StopLoss +" (must be larger than MODE_STOPLEVEL)", ERR_INVALID_INPUT_PARAMETER));
   if (MoneyManagement) {
      // Risk
      if (LE(Risk, 0))                                                 return(catch("onInit(7)  invalid input parameter Risk: "+ NumberToStr(Risk, ".1+") +" (must be positive)", ERR_INVALID_INPUT_PARAMETER));
      double lotsPerTrade = CalculateLots(false); if (IsLastError())   return(last_error);
      if (LT(lotsPerTrade, MarketInfo(Symbol(), MODE_MINLOT)))         return(catch("onInit(8)  invalid input parameter Risk: "+ NumberToStr(Risk, ".1+") +" (resulting position size smaller than MODE_MINLOT)", ERR_INVALID_INPUT_PARAMETER));
      if (GT(lotsPerTrade, MarketInfo(Symbol(), MODE_MAXLOT)))         return(catch("onInit(9)  invalid input parameter Risk: "+ NumberToStr(Risk, ".1+") +" (resulting position size larger than MODE_MAXLOT)", ERR_INVALID_INPUT_PARAMETER));
   }
   else {
      // ManualLotsize
      if (LT(ManualLotsize, MarketInfo(Symbol(), MODE_MINLOT)))        return(catch("onInit(10)  invalid input parameter ManualLotsize: "+ NumberToStr(ManualLotsize, ".1+") +" (smaller than MODE_MINLOT)", ERR_INVALID_INPUT_PARAMETER));
      if (GT(ManualLotsize, MarketInfo(Symbol(), MODE_MAXLOT)))        return(catch("onInit(11)  invalid input parameter ManualLotsize: "+ NumberToStr(ManualLotsize, ".1+") +" (larger than MODE_MAXLOT)", ERR_INVALID_INPUT_PARAMETER));
   }


   // --- old ---------------------------------------------------------------------------------------------------------------
   MinBarSize    *= Pip;
   TrailingStart *= Point;

   if (!Magic) Magic = GenerateMagicNumber();

   if (!ReadOrderLog()) return(last_error);
   return(catch("onInit(12)"));
}


/**
 * Deinitialization
 *
 * @return int - error status
 */
int onDeinit() {
   return(catch("onDeinit(1)"));
}


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   UpdateOrderStatus();
   Strategy();
   return(catch("onTick(1)"));
}


/**
 * Track open/closed positions and update statistics.
 *
 * @return bool - success status
 */
bool UpdateOrderStatus() {
   // open trade statistics are fully recalculated
   openPositions  = 0;
   openLots       = 0;
   openSwap       = 0;
   openCommission = 0;
   openPl         = 0;
   openPlNet      = 0;

   int orders = ArraySize(orders.ticket);

   // update ticket status
   for (int i=orders-1; i >= 0; i--) {                            // iterate backwards and stop at the first closed ticket
      if (orders.closeTime[i] > 0) break;                         // to increase performance
      if (!SelectTicket(orders.ticket[i], "UpdateOrderStatus(1)")) return(false);

      bool wasPending  = (orders.openType[i] == OP_UNDEFINED);
      bool isPending   = (OrderType() > OP_SELL);
      bool wasPosition = !wasPending;
      bool isOpen      = !OrderCloseTime();
      bool isClosed    = !isOpen;

      if (wasPending) {
         if (!isPending) {                                        // the pending order was filled
            onPositionOpen(i);
            wasPosition = true;                                   // mark as known open position
         }
         else if (isClosed) {                                     // the pending order was cancelled
            onOrderDelete(i);
            orders--;
            continue;
         }
      }

      if (wasPosition) {
         orders.swap      [i] = OrderSwap();
         orders.commission[i] = OrderCommission();
         orders.profit    [i] = OrderProfit();

         if (isOpen) {
            openPositions++;
            openLots       += ifDouble(orders.openType[i]==OP_BUY, orders.lots[i], -orders.lots[i]);
            openSwap       += orders.swap      [i];
            openCommission += orders.commission[i];
            openPl         += orders.profit    [i];
         }
         else /*isClosed*/ {                                      // the open position was closed
            onPositionClose(i);
            closedPositions++;                                    // update closed trade statistics
            closedLots       += orders.lots      [i];
            closedSwap       += orders.swap      [i];
            closedCommission += orders.commission[i];
            closedPl         += orders.profit    [i];
         }
      }
   }

   openPlNet   = openSwap + openCommission + openPl;
   closedPlNet = closedSwap + closedCommission + closedPl;
   totalPlNet  = openPlNet + closedPlNet;

   return(!catch("UpdateOrderStatus(2)"));
}


/**
 * Handle a PositionOpen event. The opened ticket is already selected.
 *
 * @param  int i - ticket index of the opened position
 *
 * @return bool - success status
 */
bool onPositionOpen(int i) {
   // update order log
   orders.openType  [i] = OrderType();
   orders.openTime  [i] = OrderOpenTime();
   orders.openPrice [i] = OrderOpenPrice();
   orders.swap      [i] = OrderSwap();
   orders.commission[i] = OrderCommission();
   orders.profit    [i] = OrderProfit();

   if (IsLogInfo()) {
      // #1 Stop Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was filled[ at 1.5457'2] (market: Bid/Ask[, 0.3 pip [positive ]slippage])
      int    pendingType  = orders.pendingType [i];
      double pendingPrice = orders.pendingPrice[i];

      string sType         = OperationTypeDescription(pendingType);
      string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
      string sComment      = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message       = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sPendingPrice + sComment +" was filled";

      string sSlippage = "";
      if (NE(OrderOpenPrice(), pendingPrice, Digits)) {
         double slippage = NormalizeDouble((pendingPrice-OrderOpenPrice())/Pip, 1); if (OrderType() == OP_SELL) slippage = -slippage;
            if (slippage > 0) sSlippage = ", "+ DoubleToStr(slippage, Digits & 1) +" pip positive slippage";
            else              sSlippage = ", "+ DoubleToStr(-slippage, Digits & 1) +" pip slippage";
         message = message +" at "+ NumberToStr(OrderOpenPrice(), PriceFormat);
      }
      logInfo("onPositionOpen(1)  "+ message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) + sSlippage +")");
   }

   if (IsTesting() && __ExecutionContext[EC.extReporting]) {
      Test_onPositionOpen(__ExecutionContext, OrderTicket(), OrderType(), OrderLots(), OrderSymbol(), OrderOpenTime(), OrderOpenPrice(), OrderStopLoss(), OrderTakeProfit(), OrderCommission(), OrderMagicNumber(), OrderComment());
   }
   return(!catch("onPositionOpen(2)"));
}


/**
 * Handle a PositionClose event. The closed ticket is already selected.
 *
 * @param  int i - ticket index of the closed position
 *
 * @return bool - success status
 */
bool onPositionClose(int i) {
   // update order log
   orders.closeTime [i] = OrderCloseTime();
   orders.closePrice[i] = OrderClosePrice();
   orders.swap      [i] = OrderSwap();
   orders.commission[i] = OrderCommission();
   orders.profit    [i] = OrderProfit();

   if (IsLogInfo()) {
      // #1 Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was closed at 1.5457'2 (market: Bid/Ask[, so: 47.7%/169.20/354.40])
      string sType       = OperationTypeDescription(OrderType());
      string sOpenPrice  = NumberToStr(OrderOpenPrice(), PriceFormat);
      string sClosePrice = NumberToStr(OrderClosePrice(), PriceFormat);
      string sComment    = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message     = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sOpenPrice + sComment +" was closed at "+ sClosePrice;
      logInfo("onPositionClose(1)  "+ message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
   }

   if (IsTesting() && __ExecutionContext[EC.extReporting]) {
      Test_onPositionClose(__ExecutionContext, OrderTicket(), OrderCloseTime(), OrderClosePrice(), OrderSwap(), OrderProfit());
   }
   return(!catch("onPositionClose(2)"));
}


/**
 * Handle an OrderDelete event. The deleted ticket is already selected.
 *
 * @param  int i - ticket index of the deleted order
 *
 * @return bool - success status
 */
bool onOrderDelete(int i) {
   if (IsLogInfo()) {
      // #1 Stop Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was deleted
      int    pendingType  = orders.pendingType [i];
      double pendingPrice = orders.pendingPrice[i];

      string sType         = OperationTypeDescription(pendingType);
      string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
      string sComment      = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message       = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sPendingPrice + sComment +" was deleted";
      logInfo("onOrderDelete(3)  "+ message);
   }
   return(Orders.RemoveTicket(orders.ticket[i]));
}


/**
 * Main strategy
 *
 * @return bool - success status
 */
bool Strategy() {
   double currentSpread, avgSpread;
   if (!CollectSpreads(currentSpread, avgSpread)) return(false);

   double channelHigh, channelLow, channelMean;
   if (!GetIndicatorValues(channelHigh, channelLow, channelMean)) return(false);

   int oe[];
   bool isOpenOrder = false;
   double price, stopprice, stoploss, takeprofit, newTakeProfit, newStopLoss;

   // manage open orders
   for (int i=0; i < OrdersTotal(); i++) {
      OrderSelect(i, SELECT_BY_POS, MODE_TRADES);
      if (OrderMagicNumber()!=Magic || OrderSymbol()!=Symbol())
         continue;

      isOpenOrder = true;
      RefreshRates();

      switch (OrderType()) {
         case OP_BUY:
            newTakeProfit = Ask + TakeProfit*Pip;
            newStopLoss   = Bid - StopLoss*Pip;

            if (GT(newTakeProfit, OrderTakeProfit()) && newTakeProfit-OrderTakeProfit() > TrailingStart) {                    // TODO: this is not trailing but step-trailing
               if (!OrderModifyEx(OrderTicket(), NULL, newStopLoss, newTakeProfit, NULL, Lime, NULL, oe)) return(false);      // TODO: Orders.UpdateTicket()
            }
            break;

         case OP_SELL:
            newTakeProfit = Bid - TakeProfit*Pip;
            newStopLoss   = Ask + StopLoss*Pip;

            if (LT(newTakeProfit, OrderTakeProfit()) && OrderTakeProfit() - Bid + TakeProfit*Pip > TrailingStart) {           // bug: triggered only every TakeProfit pip
               if (!OrderModifyEx(OrderTicket(), NULL, newStopLoss, newTakeProfit, NULL, Orange, NULL, oe)) return(false);    // TODO: Orders.UpdateTicket()
            }
            break;

         case OP_BUYSTOP:
            if (Bid >= channelMean) {                       // delete the order if price reached mid channel...
               if (!OrderDeleteEx(OrderTicket(), CLR_NONE, NULL, oe)) return(false);
               Orders.RemoveTicket(OrderTicket());
               isOpenOrder = false;
            }
            else {
               stopprice = Ask + BreakoutReversal*Point;    // or trail the entry limit in breakout direction

               if (LT(stopprice, OrderOpenPrice())) {
                  stoploss   = stopprice - currentSpread*Pip - StopLoss*Pip;
                  takeprofit = stopprice + TakeProfit*Pip;
                  if (!OrderModifyEx(OrderTicket(), price, stoploss, takeprofit, NULL, Lime, NULL, oe)) return(false);
                  Orders.UpdateTicket(oe.Ticket(oe), oe.OpenPrice(oe), oe.StopLoss(oe), oe.TakeProfit(oe));
               }
            }
            break;

         case OP_SELLSTOP:
            if (Bid <= channelMean) {                       // delete the order if price reached mid channel...
               if (!OrderDeleteEx(OrderTicket(), CLR_NONE, NULL, oe)) return(false);
               Orders.RemoveTicket(OrderTicket());
               isOpenOrder = false;
            }
            else {
               stopprice = Bid - BreakoutReversal*Point;    // or trail the entry limit in breakout direction

               if (GT(stopprice, OrderOpenPrice())) {
                  stoploss   = stopprice + currentSpread*Pip + StopLoss*Pip;
                  takeprofit = stopprice - TakeProfit*Pip;
                  if (!OrderModifyEx(OrderTicket(), stopprice, stoploss, takeprofit, NULL, Orange, NULL, oe)) return(false);
                  Orders.UpdateTicket(oe.Ticket(oe), oe.OpenPrice(oe), oe.StopLoss(oe), oe.TakeProfit(oe));
               }
            }
            break;
      }
   }


   // check for a channel breakout and open an order accordingly
   if (!isOpenOrder && avgSpread) {
      double barSize = iHigh(Symbol(), TimeFrame, 0) - iLow(Symbol(), TimeFrame, 0);
      if (UseSpreadMultiplier) MinBarSize = avgSpread*Pip * SpreadMultiplier;

      if (barSize > MinBarSize && avgSpread*Pip <= MaxSpread*Point) {         // TODO: should be barSize >= MinBarSize
         if (!channelHigh) return(!catch("Strategy(1)  channelHigh=0.0  Bug.ChannelCalculation="+ Bug.ChannelCalculation, ERR_ILLEGAL_STATE));

         int tradeSignal = NULL;
         if      (Bid < channelLow)         tradeSignal  = SIGNAL_LONG;
         else if (Bid > channelHigh)        tradeSignal  = SIGNAL_SHORT;
         if (tradeSignal && ReverseSignals) tradeSignal ^= 3;                 // flip long and short bits (^0011)

         if (tradeSignal != NULL) {
            double lots = CalculateLots(true); if (!lots) return(false);

            if (tradeSignal == SIGNAL_LONG) {
               price      = Ask + BreakoutReversal*Point;
               stoploss   = price - currentSpread*Pip - StopLoss*Pip;
               takeprofit = price + TakeProfit*Pip;

               if (!BreakoutReversal) OrderSendEx(Symbol(), OP_BUY,     lots, NULL,  Slippage, stoploss, takeprofit, orderComment, Magic, NULL, Blue, NULL, oe);
               else                   OrderSendEx(Symbol(), OP_BUYSTOP, lots, price, NULL,     stoploss, takeprofit, orderComment, Magic, NULL, Blue, NULL, oe);
            }
            else /*tradeSignal == SIGNAL_SHORT*/ {
               price      = Bid - BreakoutReversal*Point;
               stoploss   = price + currentSpread*Pip + StopLoss*Pip;
               takeprofit = price - TakeProfit*Pip;

               if (!BreakoutReversal) OrderSendEx(Symbol(), OP_SELL,     lots, NULL,  Slippage, stoploss, takeprofit, orderComment, Magic, NULL, Red, NULL, oe);
               else                   OrderSendEx(Symbol(), OP_SELLSTOP, lots, price, NULL,     stoploss, takeprofit, orderComment, Magic, NULL, Red, NULL, oe);
            }
            if (oe.IsError(oe)) return(false);

            Orders.AddTicket(oe.Ticket(oe), oe.Lots(oe), oe.Type(oe), oe.OpenTime(oe), oe.OpenPrice(oe), NULL, NULL, oe.StopLoss(oe), oe.TakeProfit(oe), NULL, NULL, NULL);
         }
      }
   }


   // compose chart status messages
   if (IsChart()) {
      string sSpreadWarning = "";
      if (avgSpread*Pip > MaxSpread*Point) sSpreadWarning = StringConcatenate("  => larger then MaxSpread=", DoubleToStr(MaxSpread*Point/Pip, 1), " (waiting)");

      sStatusInfo = StringConcatenate("BarSize:    ", DoubleToStr(barSize/Pip, 1), " pip    MinBarSize: ", DoubleToStr(RoundCeil(MinBarSize/Pip, 1), 1), " pip", NL,
                                      sIndicator,                                                                                                                NL,
                                      "Spread:    ",  sCurrSpread, "    Avg: ", sAvgSpread, sSpreadWarning,                                                      NL,
                                      "Unitsize:   ", sUnitSize,                                                                                                 NL);
   }
   return(!catch("Strategy(2)"));
}


/**
 * Collect and return current and average spread values. Online at least 30 ticks are collected before calculating an average.
 *
 * @param  _Out_ double currSpread - current spread in pip
 * @param  _Out_ double avgSpread  - average spread in pip or NULL if the average spread is not yet available
 *
 * @return bool - success status
 */
bool CollectSpreads(double &currSpread, double &avgSpread) {
   currSpread  = (Ask-Bid)/Pip;
   sCurrSpread = DoubleToStr(currSpread, 1);

   if (IsTesting()) {
      avgSpread  = currSpread;
      sAvgSpread = sCurrSpread;
      return(true);
   }

   double spreads[30];
   ArrayCopy(spreads, spreads, 0, 1);
   spreads[29] = currSpread;

   static int ticks = 0;
   if (ticks < 29) {
      ticks++;
      avgSpread  = NULL;
      sAvgSpread = "-";
      return(true);
   }

   double sum = 0;
   for (int i=0; i < ticks; i++) {
      sum += spreads[i];
   }
   avgSpread  = sum/ticks;
   if (avgSpread < 0.01)                           // make sure avgSpread doesn't get zero (special return value)
      avgSpread = 0.01;
   sAvgSpread = DoubleToStr(avgSpread, 2);

   return(true);
}


/**
 * Return the indicator values forming the signal channel.
 *
 * @param  _Out_ double channelHigh - current upper channel band
 * @param  _Out_ double channelLow  - current lower channel band
 * @param  _Out_ double channelMean - current mid channel
 *
 * @return bool - success status
 */
bool GetIndicatorValues(double &channelHigh, double &channelLow, double &channelMean) {
   static double lastHigh, lastLow;

   if (EntryIndicator == 1) {
      channelHigh = iMA(Symbol(), TimeFrame, IndicatorPeriods, 0, MODE_LWMA, PRICE_HIGH, 0);
      channelLow  = iMA(Symbol(), TimeFrame, IndicatorPeriods, 0, MODE_LWMA, PRICE_LOW,  0);
      channelMean = (channelHigh + channelLow)/2;
      if (IsChart()) sIndicator = StringConcatenate("Channel:   H=", NumberToStr(channelHigh, PriceFormat), "    M=", NumberToStr(channelMean, PriceFormat), "    L=", NumberToStr(channelLow, PriceFormat), "  (MovingAverage)");
   }
   else if (EntryIndicator == 2) {
      channelHigh = iBands(Symbol(), TimeFrame, IndicatorPeriods, BollingerBands.Deviation, 0, PRICE_OPEN, MODE_UPPER, 0);
      channelLow  = iBands(Symbol(), TimeFrame, IndicatorPeriods, BollingerBands.Deviation, 0, PRICE_OPEN, MODE_LOWER, 0);
      channelMean = (channelHigh + channelLow)/2;
      if (IsChart()) sIndicator = StringConcatenate("Channel:   H=", NumberToStr(channelHigh, PriceFormat), "    M=", NumberToStr(channelMean, PriceFormat), "    L=", NumberToStr(channelLow, PriceFormat), "  (BollingerBands)");
   }
   else /*EntryIndicator == 3*/ {
      channelHigh = iEnvelopes(Symbol(), TimeFrame, IndicatorPeriods, MODE_LWMA, 0, PRICE_OPEN, Envelopes.Deviation, MODE_UPPER, 0);
      channelLow  = iEnvelopes(Symbol(), TimeFrame, IndicatorPeriods, MODE_LWMA, 0, PRICE_OPEN, Envelopes.Deviation, MODE_LOWER, 0);
      channelMean = (channelHigh + channelLow)/2;
      if (IsChart()) sIndicator = StringConcatenate("Channel:   H=", NumberToStr(channelHigh, PriceFormat), "    M=", NumberToStr(channelMean, PriceFormat), "    L=", NumberToStr(channelLow, PriceFormat), "   (Envelopes)");
   }

   if (Bug.ChannelCalculation) {          // conditionally reproduce major Capella bug (for comparison only)
      if (Bid > channelMean) {
         lastHigh = channelHigh;          // use current values
         lastLow  = channelLow;
      }
      else {
         channelHigh = lastHigh;          // use expired values
         channelLow  = lastLow;
      }
   }

   int error = GetLastError();
   if (!error)                      return(true);
   if (error == ERS_HISTORY_UPDATE) return(false);
   return(!catch("GetIndicatorValues(1)", error));
}


/**
 * Generate a new magic number using parts of the current symbol.                         TODO: still contains various bugs
 *
 * @return int
 */
int GenerateMagicNumber() {
   string values = "EURUSDJPYCHFCADAUDNZDGBP";
   string base   = StrLeft(Symbol(), 3);
   string quote  = StringSubstr(Symbol(), 3, 3);

   int basePos  = StringFind(values, base, 0);
   int quotePos = StringFind(values, quote, 0);

   return(INT_MAX - AccountNumber() - basePos - quotePos);
}


/**
 * Calculate the position size to use.
 *
 * @param  bool checkLimits [optional] - whether to check the symbol's lotsize contraints (default: no)
 *
 * @return double - position size or NULL in case of errors
 */
double CalculateLots(bool checkLimits = false) {
   checkLimits = checkLimits!=0;
   static double lots, lastLots;

   if (MoneyManagement) {
      double equity = AccountEquity() - AccountCredit();
      if (LE(equity, 0)) return(!catch("CalculateLots(1)  equity: "+ DoubleToStr(equity, 2), ERR_NOT_ENOUGH_MONEY));

      double riskPerTrade = Risk/100 * equity;                          // risked equity amount per trade
      double riskPerPip   = riskPerTrade/StopLoss;                      // risked equity amount per pip

      lots = NormalizeLots(riskPerPip/PipValue(), NULL, MODE_FLOOR);    // resulting normalized position size
      if (IsEmptyValue(lots)) return(NULL);

      if (checkLimits) {
         if (LT(lots, MarketInfo(Symbol(), MODE_MINLOT)))
            return(!catch("CalculateLots(2)  equity: "+ DoubleToStr(equity, 2) +" (resulting position size smaller than MODE_MINLOT)", ERR_NOT_ENOUGH_MONEY));

         double maxLots = MarketInfo(Symbol(), MODE_MAXLOT);
         if (GT(lots, maxLots)) {
            if (LT(lastLots, maxLots)) logNotice("CalculateLots(3)  limiting position size to MODE_MAXLOT: "+ NumberToStr(maxLots, ".+") +" lot");
            lots = maxLots;
         }
      }
   }
   else {
      lots = ManualLotsize;
   }

   if (NE(lots, lastLots)) {
      SS.UnitSize(lots);
      lastLots = lots;
   }
   return(lots);
}


/**
 * Read and store the full order history.
 *
 * @return bool - success status
 */
bool ReadOrderLog() {
   ArrayResize(orders.ticket,       0);
   ArrayResize(orders.lots,         0);
   ArrayResize(orders.pendingType,  0);
   ArrayResize(orders.pendingPrice, 0);
   ArrayResize(orders.openType,     0);
   ArrayResize(orders.openTime,     0);
   ArrayResize(orders.openPrice,    0);
   ArrayResize(orders.closeTime,    0);
   ArrayResize(orders.closePrice,   0);
   ArrayResize(orders.stopLoss,     0);
   ArrayResize(orders.takeProfit,   0);
   ArrayResize(orders.swap,         0);
   ArrayResize(orders.commission,   0);
   ArrayResize(orders.profit,       0);

   openPositions    = 0;
   openLots         = 0;
   openSwap         = 0;
   openCommission   = 0;
   openPl           = 0;
   openPlNet        = 0;
   closedPositions  = 0;
   closedLots       = 0;
   closedSwap       = 0;
   closedCommission = 0;
   closedPl         = 0;
   closedPlNet      = 0;
   totalPlNet       = 0;

   // all closed positions
   int orders = OrdersHistoryTotal();
   for (int i=0; i < orders; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) return(_false(catch("ReadOrderLog(1)")));
      if (OrderMagicNumber() != Magic) continue;
      if (OrderType() > OP_SELL)       continue;
      if (OrderSymbol() != Symbol())   continue;

      Orders.AddTicket(OrderTicket(), OrderLots(), OrderType(), OrderOpenTime(), OrderOpenPrice(), OrderCloseTime(), OrderClosePrice(), OrderStopLoss(), OrderTakeProfit(), OrderSwap(), OrderCommission(), OrderProfit());
   }

   // all open tickets
   orders = OrdersTotal();
   for (i=0; i < orders; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) return(_false(catch("ReadOrderLog(2)")));
      if (OrderMagicNumber() != Magic) continue;
      if (OrderSymbol() != Symbol())   continue;

      Orders.AddTicket(OrderTicket(), OrderLots(), OrderType(), OrderOpenTime(), OrderOpenPrice(), NULL, NULL, OrderStopLoss(), OrderTakeProfit(), OrderSwap(), OrderCommission(), OrderProfit());
   }
   return(!catch("ReadOrderLog(3)"));
}


/**
 * Add a new record to the order log and update statistics.
 *
 * @param  int      ticket
 * @param  double   lots
 * @param  int      type
 * @param  datetime openTime
 * @param  double   openPrice
 * @param  datetime closeTime
 * @param  double   closePrice
 * @param  double   stopLoss
 * @param  double   takeProfit
 * @param  double   swap
 * @param  double   commission
 * @param  double   profit
 *
 * @return bool - success status
 */
bool Orders.AddTicket(int ticket, double lots, int type, datetime openTime, double openPrice, datetime closeTime, double closePrice, double stopLoss, double takeProfit, double swap, double commission, double profit) {
   int pos = SearchIntArray(orders.ticket, ticket);
   if (pos >= 0) return(!catch("Orders.AddTicket(1)  invalid parameter ticket: #"+ ticket +" (exists)", ERR_INVALID_PARAMETER));

   int pendingType, openType;
   double pendingPrice;

   if (IsPendingOrderType(type)) {
      pendingType  = type;
      pendingPrice = openPrice;
      openType     = OP_UNDEFINED;
      openTime     = NULL;
      openPrice    = NULL;
   }
   else {
      pendingType  = OP_UNDEFINED;
      pendingPrice = NULL;
      openType     = type;
   }

   ArrayPushInt   (orders.ticket,       ticket      );
   ArrayPushDouble(orders.lots,         lots        );
   ArrayPushInt   (orders.pendingType,  pendingType );
   ArrayPushDouble(orders.pendingPrice, pendingPrice);
   ArrayPushInt   (orders.openType,     openType    );
   ArrayPushInt   (orders.openTime,     openTime    );
   ArrayPushDouble(orders.openPrice,    openPrice   );
   ArrayPushInt   (orders.closeTime,    closeTime   );
   ArrayPushDouble(orders.closePrice,   closePrice  );
   ArrayPushDouble(orders.stopLoss,     stopLoss    );
   ArrayPushDouble(orders.takeProfit,   takeProfit  );
   ArrayPushDouble(orders.swap,         swap        );
   ArrayPushDouble(orders.commission,   commission  );
   ArrayPushDouble(orders.profit,       profit      );

   bool isPosition       = (openType==OP_BUY || openType==OP_SELL);
   bool isOpenPosition   = (isPosition && !closeTime);
   bool isClosedPosition = (isPosition && closeTime);
   bool isLong           = (IsLongOrderType(pendingType) || IsLongOrderType(openType));

   if (isOpenPosition) {
      openPositions++;
      openLots       += ifDouble(isLong, lots, -lots);
      openSwap       += swap;
      openCommission += commission;
      openPl         += profit;
      openPlNet       = openSwap + openCommission + openPl;
   }
   if (isClosedPosition) {
      closedPositions++;
      closedLots       += lots;
      closedSwap       += swap;
      closedCommission += commission;
      closedPl         += profit;
      closedPlNet       = closedSwap + closedCommission + closedPl;
   }
   if (isPosition) {
      totalPlNet = openPlNet + closedPlNet;
   }
   return(!catch("Orders.AddTicket(2)"));
}


/**
 * Update the order record of the specified ticket.
 *
 * @param  int    ticket
 * @param  double pendingPrice
 * @param  double stopLoss
 * @param  double takeProfit
 *
 * @return bool - success status
 */
bool Orders.UpdateTicket(int ticket, double pendingPrice, double stopLoss, double takeProfit) {
   int pos = SearchIntArray(orders.ticket, ticket);
   if (pos < 0) return(!catch("Orders.UpdateTicket(1)  invalid parameter ticket: #"+ ticket +" (not found)", ERR_INVALID_PARAMETER));

   orders.pendingPrice[pos] = pendingPrice;
   orders.stopLoss    [pos] = stopLoss;
   orders.takeProfit  [pos] = takeProfit;

   return(!catch("Orders.UpdateTicket(2)"));
}


/**
 * Remove a record from the order log.
 *
 * @param  int ticket - ticket of the record
 *
 * @return bool - success status
 */
bool Orders.RemoveTicket(int ticket) {
   int pos = SearchIntArray(orders.ticket, ticket);
   if (pos < 0)                              return(!catch("Orders.RemoveTicket(1)  invalid parameter ticket: #"+ ticket +" (not found)", ERR_INVALID_PARAMETER));
   if (orders.openType[pos] != OP_UNDEFINED) return(!catch("Orders.RemoveTicket(2)  cannot remove an already opened position: #"+ ticket, ERR_ILLEGAL_STATE));

   ArraySpliceInts   (orders.ticket,       pos, 1);
   ArraySpliceDoubles(orders.lots,         pos, 1);
   ArraySpliceInts   (orders.pendingType,  pos, 1);
   ArraySpliceDoubles(orders.pendingPrice, pos, 1);
   ArraySpliceInts   (orders.openType,     pos, 1);
   ArraySpliceInts   (orders.openTime,     pos, 1);
   ArraySpliceDoubles(orders.openPrice,    pos, 1);
   ArraySpliceInts   (orders.closeTime,    pos, 1);
   ArraySpliceDoubles(orders.closePrice,   pos, 1);
   ArraySpliceDoubles(orders.stopLoss,     pos, 1);
   ArraySpliceDoubles(orders.takeProfit,   pos, 1);
   ArraySpliceDoubles(orders.swap,         pos, 1);
   ArraySpliceDoubles(orders.commission,   pos, 1);
   ArraySpliceDoubles(orders.profit,       pos, 1);

   return(!catch("Orders.RemoveTicket(3)"));
}


/**
 * Display the current runtime status.
 *
 * @param  int error [optional] - error to display (default: none)
 *
 * @return int - the same error or the current error status if no error was passed
 */
int ShowStatus(int error = NO_ERROR) {
   if (!IsChart()) return(error);

   string sError = "";
   if      (__STATUS_INVALID_INPUT) sError = StringConcatenate("  [",                 ErrorDescription(ERR_INVALID_INPUT_PARAMETER), "]");
   else if (__STATUS_OFF          ) sError = StringConcatenate("  [switched off => ", ErrorDescription(__STATUS_OFF.reason),         "]");

   string msg = StringConcatenate(ProgramName(), "              ", sError,                                                                                      NL,
                                                                                                                                                                NL,
                                  sStatusInfo,                                                                                   // already contains linebreaks NL,
                                                                                                                                                                NL,
                                  "Open:      ", openPositions,   " positions    ", NumberToStr(openLots, ".+"),   " lots    PLn: ", DoubleToStr(openPlNet, 2), NL,
                                  "Closed:    ", closedPositions, " positions    ", NumberToStr(closedLots, ".+"), " lots    PLg: ", DoubleToStr(closedPl, 2), "    Commission: ", DoubleToStr(closedCommission, 2), "    Swap: ", DoubleToStr(closedSwap, 2), NL,
                                                                                                                                                                NL,
                                  "Total PL:  ", DoubleToStr(totalPlNet, 2),                                                                                    NL
   );

   // 3 lines margin-top for potential indicator legends
   Comment(NL, NL, NL, msg);
   if (__CoreFunction == CF_INIT) WindowRedraw();

   if (!catch("ShowStatus(1)"))
      return(error);
   return(last_error);
}


/**
 * ShowStatus: Update the string representation of the unitsize.
 *
 * @param  double size
 */
void SS.UnitSize(double size) {
   if (IsChart()) {
      sUnitSize = NumberToStr(size, ".+") +" lot";
   }
}
