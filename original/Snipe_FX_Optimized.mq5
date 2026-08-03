//+------------------------------------------------------------------+
//|                                           Snipe_FX_Optimized.mq5 |
//|                                     Virtual Stealth Execution EA |
//+------------------------------------------------------------------+
#property copyright "Snipe FX Stealth"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Input Parameters
input double LotSize = 0.01;            // Lot size
input double DistancePips = 2.0;        // Distance for pending orders (Pips)
input double SlTpDistancePips = 20.0;   // Hard SL & TP distance (Pips)
input double VirtualTakeProfitPips = 3.0; // Virtual Take Profit (Pips)
input double MaxSpreadPips = 5.0;       // Max allowed spread to enter (Pips)
input double TrailingStartPips = 1.5;   // Profit to start trailing (Pips)
input double TrailingDistancePips = 1.5;// Trail distance behind price (Pips)

//--- Global Variables
double v_buy_price  = 0;
double v_sell_price = 0;
datetime v_place_time = 0;

double pip_value = 0.10; // Original bot pip scale for Gold

double virtual_sl = 0;
ulong current_ticket = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   pip_value = 0.10; 
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if (PositionsTotal() == 0)
   {
      virtual_sl = 0;
      current_ticket = 0;

      // Rule 4: Clean up expired virtual pendings (5 seconds)
      if (v_buy_price > 0 && TimeCurrent() - v_place_time >= 5)
      {
         v_buy_price = 0;
         v_sell_price = 0;
      }

      // Rule 5 + 1: Place virtual orders if spread is valid
      if (v_buy_price == 0 && v_sell_price == 0)
      {
         if (IsSpreadValid())
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            
            v_buy_price = NormalizeDouble(ask + (DistancePips * pip_value), _Digits);
            v_sell_price = NormalizeDouble(bid - (DistancePips * pip_value), _Digits);
            v_place_time = TimeCurrent();
         }
      }

      // Check if price hits virtual orders
      if (v_buy_price > 0 || v_sell_price > 0)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         // Trigger Virtual Buy Stop
         if (ask >= v_buy_price)
         {
            // Physical emergency SL/TP (safe from StopLevel because it's 20 pips away)
            double sl = NormalizeDouble(ask - (SlTpDistancePips * pip_value), _Digits);
            double tp = NormalizeDouble(ask + (SlTpDistancePips * pip_value), _Digits);
            
            if(trade.Buy(LotSize, _Symbol, ask, sl, tp, "Virtual Buy")) {
               v_buy_price = 0;
               v_sell_price = 0;
            }
         }
         // Trigger Virtual Sell Stop
         else if (bid <= v_sell_price)
         {
            // Physical emergency SL/TP
            double sl = NormalizeDouble(bid + (SlTpDistancePips * pip_value), _Digits);
            double tp = NormalizeDouble(bid - (SlTpDistancePips * pip_value), _Digits);
            
            if(trade.Sell(LotSize, _Symbol, bid, sl, tp, "Virtual Sell")) {
               v_buy_price = 0;
               v_sell_price = 0;
            }
         }
      }
   }
   else
   {
      // We have an open position, delete virtual pendings
      v_buy_price = 0;
      v_sell_price = 0;

      TrailSLVirtual();
   }
}

//+------------------------------------------------------------------+
bool IsSpreadValid()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_spread_pips = (ask - bid) / pip_value;
   return (current_spread_pips <= MaxSpreadPips);
}

//+------------------------------------------------------------------+
void TrailSLVirtual()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      if (current_ticket != ticket) {
         current_ticket = ticket;
         virtual_sl = 0; // Reset virtual SL for new trade
      }

      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if (pos_type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - open_price;

         // Hit Virtual Take Profit?
         if (VirtualTakeProfitPips > 0 && profit >= VirtualTakeProfitPips * pip_value)
         {
            trade.PositionClose(ticket);
            virtual_sl = 0;
            current_ticket = 0;
            continue;
         }

         // Calculate and update virtual SL
         if (profit >= TrailingStartPips * pip_value)
         {
            double calculated_sl = NormalizeDouble(bid - (TrailingDistancePips * pip_value), _Digits);
            if (virtual_sl == 0 || calculated_sl > virtual_sl)
            {
               virtual_sl = calculated_sl;
            }
         }

         // Hit virtual SL? Close at market
         if (virtual_sl > 0 && bid <= virtual_sl)
         {
            trade.PositionClose(ticket);
            virtual_sl = 0;
            current_ticket = 0;
         }
      }
      else if (pos_type == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = open_price - ask;

         // Hit Virtual Take Profit?
         if (VirtualTakeProfitPips > 0 && profit >= VirtualTakeProfitPips * pip_value)
         {
            trade.PositionClose(ticket);
            virtual_sl = 0;
            current_ticket = 0;
            continue;
         }

         // Calculate and update virtual SL
         if (profit >= TrailingStartPips * pip_value)
         {
            double calculated_sl = NormalizeDouble(ask + (TrailingDistancePips * pip_value), _Digits);
            if (virtual_sl == 0 || calculated_sl < virtual_sl)
            {
               virtual_sl = calculated_sl;
            }
         }

         // Hit virtual SL? Close at market
         if (virtual_sl > 0 && ask >= virtual_sl)
         {
            trade.PositionClose(ticket);
            virtual_sl = 0;
            current_ticket = 0;
         }
      }
   }
}
