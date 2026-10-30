package com.android.systemui.unfold.updates.hinge;
import android.os.Handler;
import android.os.SystemClock;
import android.os.Trace;
import android.util.Log;
import androidx.core.util.Consumer;
import java.io.*;
import java.util.*;
/** Guest-only input adapter. Native public sensor stays registered for fallback. */
public final class PixelFold8Hinge implements Runnable {
 private static final String FRAME="/data/oneos_hinge/angle.bin";
 private static final IdentityHashMap<HingeSensorAngleProvider,PixelFold8Hinge> ACTIVE=new IdentityHashMap<>();
 private final HingeSensorAngleProvider owner;
 private final Handler handler;
 private float last=Float.NaN;
 private boolean relaying;
 private int samples;
 private PixelFold8Hinge(HingeSensorAngleProvider p){owner=p;handler=p.listenerHandler;}
 private static float read(){
  try(DataInputStream in=new DataInputStream(new FileInputStream(FRAME))){
   long age=SystemClock.elapsedRealtime()-in.readLong();float a=in.readFloat();
   return age>=0 && age<=2500 && !Float.isNaN(a) && a>=0 && a<=180 ? a:Float.NaN;
  }catch(IOException|SecurityException e){return Float.NaN;}
 }
 public static synchronized void start(HingeSensorAngleProvider p){
  stop(p);PixelFold8Hinge r=new PixelFold8Hinge(p);ACTIVE.put(p,r);r.handler.post(r);
 }
 public static synchronized void stop(HingeSensorAngleProvider p){
  PixelFold8Hinge r=ACTIVE.remove(p);if(r!=null){r.handler.removeCallbacks(r);Log.i("OneOSPixelHinge","Stopped continuous samples="+r.samples);}
 }
 public static void onPublicAngle(HingeSensorAngleProvider p,float a){
  // Read freshness here too: never allow a quantized event to fight a live relay.
  if(Float.isNaN(read()))dispatch(p,a);
 }
 private static void dispatch(HingeSensorAngleProvider p,float a){
  if(Float.isNaN(a)||a<0||a>180)return;
  for(Object c:p.listeners)((Consumer<Float>)c).accept(a);
 }
 public void run(){
  synchronized(PixelFold8Hinge.class){if(ACTIVE.get(owner)!=this)return;}
  if(!owner.started){stop(owner);return;}
  float a=read();
  if(Float.isNaN(a)){
   if(relaying){relaying=false;last=Float.NaN;Log.w("OneOSPixelHinge","Relay stale; using public sensor");}
  }else{
   if(!relaying){relaying=true;Log.i("OneOSPixelHinge","Continuous Samsung hinge active");}
   if(Float.compare(a,last)!=0){last=a;samples++;Trace.setCounter("oneos_hinge_degrees",(long)a);dispatch(owner,a);if(samples<=8)Log.i("OneOSPixelHinge","angle="+a);}
  }
  handler.postDelayed(this,20);
 }
}
