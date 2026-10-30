package com.android.systemui.wallpapers;
import android.service.wallpaper.WallpaperService;
import android.view.SurfaceControl;
import android.util.Log;
import java.lang.reflect.*;
public final class Fold8WallpaperDrawReporter {
 private static int lastDp=-1;
 private static boolean warned;
 private static Object field(WallpaperService.Engine e,String name)throws Exception{
  Field f=WallpaperService.Engine.class.getDeclaredField(name);f.setAccessible(true);return f.get(e);
 }
 public static void report(WallpaperService.Engine e){
  // Called only after Canvas has actually posted a wallpaper frame.
  if(!e.getSurfaceHolder().getSurface().isValid())return;
  try(SurfaceControl.Transaction t=new SurfaceControl.Transaction()){
   // Relayout configuration belongs to the posted window. The display
   // Context can still describe the previous panel during a fold switch.
   Object merged=field(e,"mMergedConfiguration");
   android.content.res.Configuration config=(android.content.res.Configuration)merged.getClass().getMethod("getMergedConfiguration").invoke(merged);
   int dp=config.smallestScreenWidthDp;
   if(dp<=0)return;
   Object wrapper=SurfaceControl.Transaction.class.getMethod("getWrapper").invoke(t);
   Object ext=Class.forName("android.view.ITransactionWrapper").getMethod("getExtImpl").invoke(wrapper);
   Class.forName("android.view.ITransactionExt").getMethod("setExtraSummary",int.class).invoke(ext,dp);
   Object session=field(e,"mSession"),window=field(e,"mWindow");
   if(session==null||window==null)return;
   Class.forName("android.view.IWindowSession").getMethod("finishDrawing",Class.forName("android.view.IWindow"),SurfaceControl.Transaction.class,int.class).invoke(session,window,t,Integer.MAX_VALUE);
   if(lastDp!=dp){lastDp=dp;Log.i("OneOSWallpaperDraw","Reported posted wallpaper frame, smallestWidthDp="+dp);}
  }catch(Exception ex){if(!warned){warned=true;Log.w("OneOSWallpaperDraw","Wallpaper draw metadata unavailable",ex);}}
 }
}
