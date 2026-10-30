package com.android.systemui.unfold.updates.hinge;
import android.hardware.SensorEventListener;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;
import java.io.*;
import java.util.IdentityHashMap;
import androidx.core.util.Consumer;
public final class Fold8HingeRelay implements Runnable {
 private static final String FRAME="/data/oneos_hinge/angle.bin";
 private static final IdentityHashMap<HingeSensorAngleProvider,Fold8HingeRelay> active=new IdentityHashMap<>();
 private final HingeSensorAngleProvider owner;
 private final Handler handler;
 private float last=Float.NaN;
 private Fold8HingeRelay(HingeSensorAngleProvider p,Handler h){owner=p;handler=h;}
 private static float angle(){
  try(DataInputStream in=new DataInputStream(new FileInputStream(FRAME))){
   long age=SystemClock.elapsedRealtime()-in.readLong();float a=in.readFloat();
   return age>=0&&age<=2500&&!Float.isNaN(a)&&a>=0&&a<=180?a:Float.NaN;
  }catch(IOException e){return Float.NaN;}
 }
 public static synchronized boolean startIfFresh(SensorEventListener l,Handler h){
  if(!(l instanceof HingeSensorAngleProvider.HingeAngleSensorListener)||Float.isNaN(angle()))return false;
  HingeSensorAngleProvider p=((HingeSensorAngleProvider.HingeAngleSensorListener)l).this$0;
  Fold8HingeRelay old=active.remove(p);
  if(old!=null)old.handler.removeCallbacks(old);
  Fold8HingeRelay next=new Fold8HingeRelay(p,h);
  active.put(p,next);
  h.postDelayed(next,20);
  Log.i("OneOSFold8Hinge","Using Samsung continuous angle via guest relay");return true;
 }
 public void run(){
  synchronized(Fold8HingeRelay.class){
   if(active.get(owner)!=this)return;
   if(!owner.started){active.remove(owner);return;}
  }
  float a=angle();
  if(!Float.isNaN(a)&&Float.compare(a,last)!=0){
   last=a;
   for(Consumer<Float> c:HingeSensorAngleProvider.access$getListeners$p(owner))c.accept(a);
  }
  handler.postDelayed(this,20);
 }
}
