import * as Location from 'expo-location';
import * as Notifications from 'expo-notifications';
import * as TaskManager from 'expo-task-manager';
import AsyncStorage from '@react-native-async-storage/async-storage';

export const GEOFENCE_TASK = 'ledger-north-receipt-geofences';
export const REMINDER_CATEGORY = 'receipt-capture';
export type Fence = {id:string;organization_id:string;name:string;latitude:number;longitude:number;radius_m:number;dwell_seconds:number;enabled:boolean};

const key = (id:string) => 'geofence-state:'+id;
const notificationId = (id:string) => 'receipt-reminder:'+id;

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true,
    shouldShowList: true,
    shouldPlaySound: true,
    shouldSetBadge: false
  })
});

TaskManager.defineTask(GEOFENCE_TASK, async ({data,error}) => {
  if(error || !data) return;
  const event = data as {eventType:number;region:Location.LocationRegion};
  const regionId=event.region.identifier;
  if(!regionId) return;
  const raw=await AsyncStorage.getItem('configured-geofences');
  const fences: Fence[] = raw ? JSON.parse(raw) : [];
  const fence=fences.find(f=>f.id===regionId&&f.enabled);
  if(!fence) return;
  if(event.eventType===Location.GeofencingEventType.Exit){
    await Notifications.cancelScheduledNotificationAsync(notificationId(regionId)).catch(()=>{});
    await AsyncStorage.removeItem(key(regionId));
    return;
  }
  if(event.eventType!==Location.GeofencingEventType.Enter) return;
  // Scheduled local notification allows iOS to deliver after the app is suspended.
  // This is an approximate dwell reminder: background exits can arrive late.
  const existing=await AsyncStorage.getItem(key(regionId));
  if(existing) return;
  const at=Date.now();
  await AsyncStorage.setItem(key(regionId),String(at));
  await Notifications.scheduleNotificationAsync({
    identifier:notificationId(regionId),
    content:{
      title:'Receipt reminder',
      body:'At '+fence.name+'? Photograph your receipt for Ledger North.',
      data:{screen:'capture',organizationId:fence.organization_id,geofenceId:fence.id},
      categoryIdentifier:REMINDER_CATEGORY
    },
    trigger:{type:Notifications.SchedulableTriggerInputTypes.TIME_INTERVAL,seconds:fence.dwell_seconds}
  });
});

export async function configureGeofences(fences:Fence[]):Promise<void>{
  const active=fences.filter(f=>f.enabled);
  // iOS permits only 20 actively monitored regions; fail visibly rather than silently lose one.
  if(active.length>20) throw new Error('This device supports at most 20 active receipt locations. Disable some locations.');
  const fg=await Location.requestForegroundPermissionsAsync();
  if(fg.status!=='granted') throw new Error('Location access is required for receipt reminders.');
  const bg=await Location.requestBackgroundPermissionsAsync();
  if(bg.status!=='granted') throw new Error('Always/background location access is required for arrival reminders.');
  const permission=await Notifications.requestPermissionsAsync();
  if(!permission.granted) throw new Error('Notification permission is required.');
  await Notifications.setNotificationChannelAsync('receipts',{name:'Receipt reminders',importance:Notifications.AndroidImportance.DEFAULT});
  await AsyncStorage.setItem('configured-geofences',JSON.stringify(active));
  if(active.length===0){
    if(await Location.hasStartedGeofencingAsync(GEOFENCE_TASK))await Location.stopGeofencingAsync(GEOFENCE_TASK);
    return;
  }
  await Location.startGeofencingAsync(GEOFENCE_TASK,active.map(f=>({
    identifier:f.id,latitude:f.latitude,longitude:f.longitude,radius:f.radius_m,
    notifyOnEnter:true,notifyOnExit:true
  })));
}
