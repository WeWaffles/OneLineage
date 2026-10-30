package com.android.systemui.unfold;
import android.hardware.display.DisplayManager;
import android.view.Display;
import android.view.WindowManager;
import android.util.Log;
import java.util.ArrayList;
import java.util.List;
import java.lang.reflect.Method;
public final class Fold8RevealGeometry {
 public static List refresh(DisplayManager manager,List fallback){
  try{
   Class<?> info=Class.forName("android.view.DisplayInfo");
   Method read=Display.class.getMethod("getDisplayInfo",info);
   ArrayList<Object> current=new ArrayList<>();
   for(Display display:manager.getDisplays("android.hardware.display.category.ALL_INCLUDING_DISABLED")){
    Object value=info.getConstructor().newInstance();
    if(Boolean.TRUE.equals(read.invoke(display,value))&&info.getField("type").getInt(value)==1)current.add(value);
   }
   if(!current.isEmpty())return current;
  }catch(ReflectiveOperationException|RuntimeException e){Log.w("OneOSFold8Reveal","Using cached display geometry",e);}
  return fallback;
 }
 public static void bounds(WindowManager.LayoutParams p){Log.i("OneOSFold8Reveal",p.getTitle()+" bounds="+p.width+"x"+p.height);}
}
