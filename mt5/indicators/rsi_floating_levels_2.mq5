//------------------------------------------------------------------
#property copyright "www.forex-tsd.com"
#property link      "www.forex-tsd.com"
//------------------------------------------------------------------
#property indicator_separate_window
#property indicator_buffers 6
#property indicator_plots   5

#property indicator_label1  "rsi OB/OS zone"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  C'221,247,221',clrMistyRose
#property indicator_label2  "rsi up level"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrLimeGreen
#property indicator_style2  STYLE_DOT
#property indicator_label3  "rsi middle level"
#property indicator_type3   DRAW_LINE
#property indicator_color3  DimGray
#property indicator_style3  STYLE_DOT
#property indicator_label4  "rsi down level"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrPaleVioletRed
#property indicator_style4  STYLE_DOT
#property indicator_label5  "rsi"
#property indicator_type5   DRAW_LINE
#property indicator_color5  DarkGray
#property indicator_width5  2
  

//
//
//
//
//

enum rsiMethods
{
   _rsi, // rsi
   _wil, // Wilder's rsi
   _rsx, // rsx
   _cut  // Cuttler's rsi
};
input int        RsiPeriod    = 14;   // Rsi period
input rsiMethods RsiMethod    = _rsi; // Rsi method 
input int        MinMaxPeriod = 100;  // Floating levels period
input double     LevelUp      = 80.0; // Up level %
input double     LevelDown    = 20.0; // Down level %
input double     SmoothPeriod =   8;  // Smoothing period
input double     SmoothPhase  =   0;  // Smoothing phase


double rsi[];
double fill1[];
double fill2[];
double levelUp[];
double levelMi[];
double levelDn[];

//------------------------------------------------------------------
//                                                                  
//------------------------------------------------------------------
//
//
//
//
//

int OnInit()
{
   SetIndexBuffer(0,fill1  ,INDICATOR_DATA);
   SetIndexBuffer(1,fill2  ,INDICATOR_DATA);
   SetIndexBuffer(2,levelUp,INDICATOR_DATA);
   SetIndexBuffer(3,levelMi,INDICATOR_DATA);
   SetIndexBuffer(4,levelDn,INDICATOR_DATA);
   SetIndexBuffer(5,rsi    ,INDICATOR_DATA);
   IndicatorSetString(INDICATOR_SHORTNAME," RSI floating levels ("+(string)RsiPeriod+","+(string)MinMaxPeriod+")");
      return(0);
}

//------------------------------------------------------------------
//                                                                  
//------------------------------------------------------------------
//
//
//
//
//

int OnCalculate (const int rates_total,
                 const int prev_calculated,
                 const int begin,
                 const double& price[] )
{

   //
   //
   //
   //
   //
   
   for (int i=(int)MathMax(prev_calculated-1,0); i<rates_total; i++)
   {
      rsi[i] = iSmooth(iRsi(price[i],RsiPeriod,RsiMethod,i,rates_total),SmoothPeriod,SmoothPhase,i,rates_total);
      double min = rsi[i];
      double max = rsi[i];
         for(int k=1; k<MinMaxPeriod && (i-k)>=0; k++)
            {
               min = rsi[i-k]< min ? rsi[i-k]: min;
               max = rsi[i-k]> max ? rsi[i-k]: max;
            }
            double range = max-min;
               levelDn[i] = min+range*LevelDown/100.0;
               levelMi[i] = min+range*0.5;
               levelUp[i] = min+range*LevelUp/100.0;
               fill1[i]   = rsi[i];
               fill2[i]   = rsi[i];
                  if (rsi[i]>levelUp[i]) fill2[i] = levelUp[i];
                  if (rsi[i]<levelDn[i]) fill2[i] = levelDn[i];
   }
   return(rates_total);
}


//------------------------------------------------------------------
//
//------------------------------------------------------------------
//
//
//
//
//
//

double workRsi[][13];
#define _price  0
#define _change 1
#define _changa 2

double iRsi(double price, double period, rsiMethods rsiMode, int r, int bars, int instanceNo=0)
{
   if (ArrayRange(workRsi,0)!=bars) ArrayResize(workRsi,bars);
      int z = instanceNo*13; 
   
   //
   //
   //
   //
   //
   
   workRsi[r][z+_price] = price;
   switch (rsiMode)
   {
      case _rsi:
         if (r<period)
            {
               int k; double sum = 0; for (k=0; k<period && (r-k-1)>=0; k++) sum += MathAbs(workRsi[r-k][z+_price]-workRsi[r-k-1][z+_price]);
                  workRsi[r][z+_change] = (workRsi[r][z+_price]-workRsi[0][z+_price])/MathMax(k,1);
                  workRsi[r][z+_changa] =                                         sum/MathMax(k,1);
            }
         else
            {
               double alpha = 1.0/period; 
               double change = workRsi[r][z+_price]-workRsi[r-1][z+_price];
                               workRsi[r][z+_change] = workRsi[r-1][z+_change] + alpha*(        change  - workRsi[r-1][z+_change]);
                               workRsi[r][z+_changa] = workRsi[r-1][z+_changa] + alpha*(MathAbs(change) - workRsi[r-1][z+_changa]);
            }
         if (workRsi[r][z+_changa] != 0)
               return(50.0*(workRsi[r][z+_change]/workRsi[r][z+_changa]+1));
         else  return(50.0);
         
      //
      //
      //
      //
      //
      
      case _wil :
         if (r>0)
         {
            workRsi[r][z+1] = iSmma(0.5*(MathAbs(workRsi[r][z+_price]-workRsi[r-1][z+_price])+(workRsi[r][z+_price]-workRsi[r-1][z+_price])),0.5*(period-1),r,bars,instanceNo*2+0);
            workRsi[r][z+2] = iSmma(0.5*(MathAbs(workRsi[r][z+_price]-workRsi[r-1][z+_price])-(workRsi[r][z+_price]-workRsi[r-1][z+_price])),0.5*(period-1),r,bars,instanceNo*2+1);
            if((workRsi[r][z+1] + workRsi[r][z+2]) != 0) 
                  return(100.0 * workRsi[r][z+1]/(workRsi[r][z+1] + workRsi[r][z+2]));
            else  return(50);
         }            
         else return(50);

      //
      //
      //
      //
      //

      case _rsx :     
         if (r<period) { for (int k=1; k<13; k++) workRsi[r][k+z] = 0; return(50); }  
         //
         //
         //
         //
         //
         
         {
            double Kg  = (3.0)/(2.0+period), Hg = 1.0-Kg; 
            double mom = workRsi[r][_price+z]-workRsi[r-1][_price+z];
            double moa = MathAbs(mom);
            for (int k=0; k<3; k++)
            {
               int kk = k*2;
               workRsi[r][z+kk+1] = Kg*mom                + Hg*workRsi[r-1][z+kk+1];
               workRsi[r][z+kk+2] = Kg*workRsi[r][z+kk+1] + Hg*workRsi[r-1][z+kk+2]; mom = 1.5*workRsi[r][z+kk+1] - 0.5 * workRsi[r][z+kk+2];
               workRsi[r][z+kk+7] = Kg*moa                + Hg*workRsi[r-1][z+kk+7];
               workRsi[r][z+kk+8] = Kg*workRsi[r][z+kk+7] + Hg*workRsi[r-1][z+kk+8]; moa = 1.5*workRsi[r][z+kk+7] - 0.5 * workRsi[r][z+kk+8];
            }
            if (moa != 0)
                 return(MathMax(MathMin((mom/moa+1.0)*50.0,100.00),0.00)); 
            else return(50);
         }            
            
      //
      //
      //
      //
      //
      
      case _cut :
         {
            double sump = 0;
            double sumn = 0;
            for (int k=0; k<period && (r-k-1)>=0; k++)
            {
               double diff = workRsi[r-k][z+_price]-workRsi[r-k-1][z+_price];
                  if (diff > 0) sump += diff;
                  if (diff < 0) sumn -= diff;
            }
            if (sumn > 0)
                  return(100.0-100.0/(1.0+sump/sumn));
            else  return(50);
         }            
   } 
   return(price);
}

//
//
//
//
//
//

double workSmma[][2];
double iSmma(double price, double period, int r, int bars, int instanceNo=0)
{
   if (ArrayRange(workSmma,0)!= bars) ArrayResize(workSmma,bars);

   //
   //
   //
   //
   //

   if (r<period)
         workSmma[r][instanceNo] = price;
   else  workSmma[r][instanceNo] = workSmma[r-1][instanceNo]+(price-workSmma[r-1][instanceNo])/period;
   return(workSmma[r][instanceNo]);
}

//------------------------------------------------------------------
//
//------------------------------------------------------------------
//
//
//
//
//

double wrk[][10];

#define bsmax  5
#define bsmin  6
#define volty  7
#define vsum   8
#define avolty 9

//
//
//
//
//

double iSmooth(double price, double length, double phase, int r, int bars, int s=0)
{
   if (length <=1) return(price);
   if (ArrayRange(wrk,0) != bars) ArrayResize(wrk,bars); s*= 10;
   
      if (r==0) { int k; for(k=0; k<7; k++) wrk[r][k+s]=price; for(; k<10; k++) wrk[r][k+s]=0; return(price); }

   //
   //
   //
   //
   //
   
      double len1   = MathMax(MathLog(MathSqrt(0.5*(length-1)))/MathLog(2.0)+2.0,0);
      double pow1   = MathMax(len1-2.0,0.5);
      double del1   = price - wrk[r-1][bsmax+s];
      double del2   = price - wrk[r-1][bsmin+s];
      double div    = 1.0/(10.0+10.0*(MathMin(MathMax(length-10,0),100))/100);
      int    forBar = (int)MathMin(r,10);
	
         wrk[r][volty+s] = 0;
               if(MathAbs(del1) > MathAbs(del2)) wrk[r][volty+s] = MathAbs(del1); 
               if(MathAbs(del1) < MathAbs(del2)) wrk[r][volty+s] = MathAbs(del2); 
         wrk[r][vsum+s] =	wrk[r-1][vsum+s] + (wrk[r][volty+s]-wrk[r-forBar][volty+s])*div;
         
         //
         //
         //
         //
         //
   
         wrk[r][avolty+s] = wrk[r-1][avolty+s]+(2.0/(MathMax(4.0*length,30)+1.0))*(wrk[r][vsum+s]-wrk[r-1][avolty+s]);
         double dVolty = 0;   
            if (wrk[r][avolty+s] > 0)
               dVolty = wrk[r][volty+s]/wrk[r][avolty+s];
	               if (dVolty > MathPow(len1,1.0/pow1)) dVolty = MathPow(len1,1.0/pow1);
                  if (dVolty < 1)                      dVolty = 1.0;

      //
      //
      //
      //
      //
	        
   	double pow2 = MathPow(dVolty, pow1);
      double len2 = MathSqrt(0.5*(length-1))*len1;
      double Kv   = MathPow(len2/(len2+1), MathSqrt(pow2));

         if (del1 > 0) wrk[r][bsmax+s] = price; else wrk[r][bsmax+s] = price - Kv*del1;
         if (del2 < 0) wrk[r][bsmin+s] = price; else wrk[r][bsmin+s] = price - Kv*del2;
	
   //
   //
   //
   //
   //
      
      double R     = MathMax(MathMin(phase,100),-100)/100.0 + 1.5;
      double beta  = 0.45*(length-1)/(0.45*(length-1)+2);
      double alpha = MathPow(beta,pow2);

         wrk[r][0+s] = price + alpha*(wrk[r-1][0+s]-price);
         wrk[r][1+s] = (price - wrk[r][0+s])*(1-beta) + beta*wrk[r-1][1+s];
         wrk[r][2+s] = (wrk[r][0+s] + R*wrk[r][1+s]);
         wrk[r][3+s] = (wrk[r][2+s] - wrk[r-1][4+s])*MathPow((1-alpha),2) + MathPow(alpha,2)*wrk[r-1][3+s];
         wrk[r][4+s] = (wrk[r-1][4+s] + wrk[r][3+s]); 

   //
   //
   //
   //
   //

   return(wrk[r][4+s]);
}