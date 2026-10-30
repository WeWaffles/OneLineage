import android.content.Context;
import android.hardware.*;
import android.os.*;
import java.io.*;
public final class OneOSAngleRelay {
 private static volatile float last=Float.NaN;
 private static long lastWrite;
 private static File frame;
 private static void write(float a){
  long now=SystemClock.elapsedRealtime();if(now-lastWrite<16)return;
  try{
   File tmp=new File(frame.getPath()+".new");
   try(DataOutputStream out=new DataOutputStream(new FileOutputStream(tmp))){out.writeLong(now);out.writeFloat(a);}
   if(!tmp.renameTo(frame))throw new IOException("rename failed");lastWrite=now;
  }catch(IOException e){System.err.println("FRAME_ERROR "+e);}
 }
 public static void main(String[] args)throws Exception{
  frame=new File(args[0]);final int guest=Integer.parseInt(args[1]);
  Looper.prepareMainLooper();
  Object at=Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
  Context c=(Context)at.getClass().getMethod("getSystemContext").invoke(at);
  SensorManager sm=(SensorManager)c.getSystemService(Context.SENSOR_SERVICE);Handler h=new Handler(Looper.myLooper());
  Sensor s=sm.getDefaultSensor(65686,false);
  if(s==null||!s.getName().startsWith("Folding Angle"))throw new IllegalStateException("Samsung angle sensor missing");
  SensorEventListener l=new SensorEventListener(){public void onAccuracyChanged(Sensor s,int a){}public void onSensorChanged(SensorEvent e){float a=e.values[0];if(!Float.isNaN(a)&&a>=0&&a<=180){last=a;write(a);}}};
  if(!sm.registerListener(l,s,SensorManager.SENSOR_DELAY_GAME,h))throw new IllegalStateException("Samsung sensor denied");
  System.out.println("READY sensor=65686 uid="+android.os.Process.myUid()+" guest="+guest);
  h.postDelayed(new Runnable(){public void run(){
   if(!new File("/proc/"+guest).exists()){sm.unregisterListener(l);System.exit(0);}
   if(!Float.isNaN(last))write(last);
   h.postDelayed(this,1000);
  }},1000);
  Looper.loop();
 }
}
