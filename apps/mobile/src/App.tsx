import React,{useCallback,useEffect,useState} from 'react';
import {ActivityIndicator,Alert,Button,FlatList,Image,Platform,SafeAreaView,ScrollView,StyleSheet,Text,TextInput,TouchableOpacity,View} from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {createClient} from '@supabase/supabase-js';
import * as ImagePicker from 'expo-image-picker';
import * as Notifications from 'expo-notifications';
import {StatusBar} from 'expo-status-bar';
import {configureGeofences,type Fence} from './geofences';

const url=process.env.EXPO_PUBLIC_SUPABASE_URL||'';
const key=process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY||'';
const api=(process.env.EXPO_PUBLIC_API_URL||'').replace(/\/$/,'');
const supabase=createClient(url||'https://unconfigured.invalid',key||'missing',{
  auth:{storage:AsyncStorage,autoRefreshToken:true,persistSession:true,detectSessionInUrl:false}
});
type Membership={organization_id:string;role:string;organizations:{name:string}|{name:string}[]|null};
type Intake={id:string;receipt_id:string;classification:string;status:string;merchant_candidate:string|null;total_candidate:number|null;created_at:string};
type Captured={uri:string;mimeType:string;fileName:string};
const styles=StyleSheet.create({
  screen:{flex:1,backgroundColor:'#f4f6f9'},content:{padding:20,gap:14},header:{backgroundColor:'#14233d',padding:20,gap:6},
  title:{fontSize:25,fontWeight:'700',color:'#fff'},subtitle:{color:'#ced9e7'},card:{backgroundColor:'#fff',padding:18,borderRadius:12,gap:12},
  field:{borderWidth:1,borderColor:'#c8d0da',borderRadius:8,padding:12,backgroundColor:'#fff'},
  heading:{fontSize:18,fontWeight:'700',color:'#17233b'},small:{fontSize:13,color:'#56657b'},row:{flexDirection:'row',gap:10,alignItems:'center'},
  button:{backgroundColor:'#255bba',padding:14,borderRadius:8,alignItems:'center'},
  buttonText:{color:'#fff',fontWeight:'700'},secondary:{backgroundColor:'#e5eaf2',padding:12,borderRadius:8,alignItems:'center'},
  muted:{color:'#36465c'},error:{color:'#b91c1c'},photo:{width:'100%',height:220,borderRadius:8}
});
function Action({title,onPress,disabled=false,secondary=false}:{title:string;onPress:()=>void;disabled?:boolean;secondary?:boolean}){
 return <TouchableOpacity disabled={disabled} onPress={onPress} style={[secondary?styles.secondary:styles.button,disabled&&{opacity:.4}]}><Text style={secondary?styles.muted:styles.buttonText}>{title}</Text></TouchableOpacity>;
}
function App(){
 const [session,setSession]=useState<Awaited<ReturnType<typeof supabase.auth.getSession>>['data']['session']>(null);
 const [loading,setLoading]=useState(true);
 const [email,setEmail]=useState(''),[password,setPassword]=useState('');
 const [memberships,setMemberships]=useState<Membership[]>([]);
 const [organizationId,setOrganizationId]=useState('');
 const [fences,setFences]=useState<Fence[]>([]);
 const [pendingFenceId,setPendingFenceId]=useState<string|null>(null);
 const [capture,setCapture]=useState<Captured|null>(null);
 const [kind,setKind]=useState<'expense'|'incoming_payment'>('expense');
 const [consent,setConsent]=useState(false);
 const [busy,setBusy]=useState(false);
 const [message,setMessage]=useState('');
 const [intakes,setIntakes]=useState<Intake[]>([]);
 const [screen,setScreen]=useState<'home'|'capture'|'review'>('home');
 const selected=memberships.find(m=>m.organization_id===organizationId);
 const orgName=selected?(Array.isArray(selected.organizations)?selected.organizations[0]?.name:selected.organizations?.name):'Organization';
 const refresh=useCallback(async()=>{
  const {data,error}=await supabase.from('organization_members').select('organization_id,role,organizations(name)');
  if(error)throw error;
  const rows=(data||[]) as unknown as Membership[];
  setMemberships(rows);
  setOrganizationId(current=>rows.some(m=>m.organization_id===current)?current:rows[0]?.organization_id||'');
 },[]);
 const loadFences=useCallback(async()=>{
  if(!organizationId)return;
  const [f,r]=await Promise.all([
   supabase.from('receipt_geofences').select('id,organization_id,name,latitude,longitude,radius_m,dwell_seconds,enabled').eq('organization_id',organizationId).eq('enabled',true),
   supabase.from('receipt_intake_reviews').select('id,receipt_id,classification,status,merchant_candidate,total_candidate,created_at').eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(30)
  ]);
  if(f.error)throw f.error;
  if(r.error)throw r.error;
  setFences(f.data as Fence[]);
  setIntakes(r.data as Intake[]);
 },[organizationId]);
 useEffect(()=>{
  supabase.auth.getSession().then(({data})=>{setSession(data.session);setLoading(false)});
  const {data:listener}=supabase.auth.onAuthStateChange((_event,s)=>setSession(s));
  return ()=>listener.subscription.unsubscribe();
 },[]);
 useEffect(()=>{if(session)void refresh().catch(e=>setMessage(e.message));else{setMemberships([]);setOrganizationId('');}},[session,refresh]);
 useEffect(()=>{void loadFences().catch(e=>setMessage(e.message));},[loadFences]);
 useEffect(()=>{
  const sub=Notifications.addNotificationResponseReceivedListener(response=>{
   const data=response.notification.request.content.data;
   if(data.screen==='capture'&&typeof data.organizationId==='string'){
    setOrganizationId(data.organizationId);
    setPendingFenceId(typeof data.geofenceId==='string'?data.geofenceId:null);
    setScreen('capture');
   }
  });
  void Notifications.getLastNotificationResponseAsync().then(response=>{
   const data=response?.notification.request.content.data;
   if(data?.screen==='capture'&&typeof data.organizationId==='string'){
    setOrganizationId(data.organizationId);
    setPendingFenceId(typeof data.geofenceId==='string'?data.geofenceId:null);
    setScreen('capture');
   }
  });
  return ()=>sub.remove();
 },[]);
 async function run(fn:()=>Promise<void>){setBusy(true);setMessage('');try{await fn();}catch(e){setMessage(e instanceof Error?e.message:String(e));}finally{setBusy(false);}}
 async function enableReminders(){await run(async()=>{
  // Monitor only the selected tenant's locations to prevent cross-organization confusion.
  await configureGeofences(fences);
  setMessage('Receipt location reminders enabled. Background delivery is best effort.');
 });}
 async function choosePhoto(camera:boolean){await run(async()=>{
  const perm=camera?await ImagePicker.requestCameraPermissionsAsync():await ImagePicker.requestMediaLibraryPermissionsAsync();
  if(!perm.granted)throw new Error('Camera or photo library permission denied.');
  const result=camera?await ImagePicker.launchCameraAsync({quality:.8,allowsEditing:false}):
   await ImagePicker.launchImageLibraryAsync({mediaTypes:['images'],quality:.8});
  if(result.canceled)return;
  const asset=result.assets[0];
  if(!asset?.uri)throw new Error('No image selected');
  setCapture({uri:asset.uri,mimeType:asset.mimeType==='image/png'?'image/png':'image/jpeg',
   fileName:asset.fileName||('receipt-'+Date.now()+'.jpg')});
 });}
 async function submit(){await run(async()=>{
  if(!capture||!organizationId||!consent||!session||!api)throw new Error('Select a photo and authorize OCR processing.');
  const binary=await fetch(capture.uri);
  const blob=await binary.blob();
  if(blob.size>8388608)throw new Error('Receipt must be smaller than 8 MiB');
  const upload=await fetch(api+'/organizations/'+organizationId+'/receipts',{
   method:'POST',headers:{Authorization:'Bearer '+session.access_token,'Content-Type':capture.mimeType,
    'X-Original-Filename':capture.fileName},body:blob
  });
  const uploaded=await upload.json() as {id?:string;error?:string};
  if(!upload.ok||!uploaded.id)throw new Error(uploaded.error||'Receipt upload failed');
  const ocr=await fetch(api+'/organizations/'+organizationId+'/receipts/'+uploaded.id+'/ocr',{
   method:'POST',headers:{Authorization:'Bearer '+session.access_token,'Content-Type':'application/json','X-External-OCR-Consent':'true'},
   body:'{}'
  });
  const extracted=await ocr.json() as {error?:string};
  if(!ocr.ok)throw new Error(extracted.error||'OCR failed. The original receipt remains uploaded for retry.');
  const {error}=await supabase.rpc('submit_receipt_intake',{
   p_org:organizationId,p_receipt:uploaded.id,p_kind:kind,p_geofence:pendingFenceId
  });
  if(error)throw error;
  setCapture(null);setConsent(false);setPendingFenceId(null);
  await loadFences();setScreen('review');
  setMessage('Receipt extracted and placed into the organization review queue. No ledger entry has been posted.');
 });}
 if(!url||!key||!api)return <SafeAreaView style={styles.screen}><View style={styles.content}><Text style={styles.heading}>Ledger North setup required</Text><Text>Set EXPO_PUBLIC_SUPABASE_URL, EXPO_PUBLIC_SUPABASE_ANON_KEY and EXPO_PUBLIC_API_URL in your EAS environment.</Text></View></SafeAreaView>;
 if(loading)return <ActivityIndicator style={{flex:1}}/>;
 if(!session)return <SafeAreaView style={styles.screen}><StatusBar style="dark"/><View style={styles.content}><Text style={styles.heading}>Ledger North</Text><Text style={styles.small}>Sign in with your organization account.</Text><TextInput style={styles.field} autoCapitalize="none" keyboardType="email-address" placeholder="Email address" value={email} onChangeText={setEmail}/><TextInput style={styles.field} secureTextEntry placeholder="Password" value={password} onChangeText={setPassword}/><Action title="Sign in" disabled={busy} onPress={()=>void run(async()=>{const {error}=await supabase.auth.signInWithPassword({email,password});if(error)throw error;})}/>{!!message&&<Text style={styles.error}>{message}</Text>}</View></SafeAreaView>;
 return <SafeAreaView style={styles.screen}><StatusBar style="light"/>
  <View style={styles.header}><Text style={styles.title}>Ledger North</Text><Text style={styles.subtitle}>{orgName} · Receipt Capture</Text></View>
  <View style={[styles.row,{padding:12,justifyContent:'space-around'}]}>
   <Action secondary title="Locations" onPress={()=>setScreen('home')}/>
   <Action secondary title="Capture" onPress={()=>setScreen('capture')}/>
   <Action secondary title="Review" onPress={()=>setScreen('review')}/>
  </View>
  <ScrollView contentContainerStyle={styles.content}>
   {memberships.length>1&&<View style={styles.card}><Text style={styles.heading}>Business</Text>{memberships.map(m=><Action key={m.organization_id} secondary={organizationId!==m.organization_id} title={(Array.isArray(m.organizations)?m.organizations[0]?.name:m.organizations?.name)||'Business'} onPress={()=>{setOrganizationId(m.organization_id);setPendingFenceId(null);setScreen('home');}}/>)}</View>}
   {screen==='home'&&<View style={styles.card}>
    <Text style={styles.heading}>Receipt reminder locations</Text>
    <Text style={styles.small}>Your organization principal manages these locations. Enable background monitoring on this device. Arrival notifications appear after the configured dwell time, subject to operating-system scheduling.</Text>
    {fences.map(f=><View key={f.id} style={{paddingVertical:8,borderBottomWidth:1,borderColor:'#e3e8ef'}}><Text style={styles.heading}>{f.name}</Text><Text style={styles.small}>{f.radius_m} m radius · {Math.round(f.dwell_seconds/60)} minute dwell</Text></View>)}
    {fences.length===0&&<Text>No locations configured.</Text>}
    <Action title="Enable location reminders" disabled={busy} onPress={()=>void enableReminders()}/>
    <Action secondary title="Refresh locations" disabled={busy} onPress={()=>void run(loadFences)}/>
   </View>}
   {screen==='capture'&&<View style={styles.card}>
    <Text style={styles.heading}>Photograph a receipt</Text>
    <Text style={styles.small}>Choose whether this documents an outgoing expense or evidence of a customer payment. Both enter a review queue. Classification is not inferred from a payment screenshot.</Text>
    <Action title="Take photo" disabled={busy} onPress={()=>void choosePhoto(true)}/>
    <Action secondary title="Select existing photo" disabled={busy} onPress={()=>void choosePhoto(false)}/>
    {capture&&<Image source={{uri:capture.uri}} style={styles.photo} resizeMode="contain"/>}
    <Text style={styles.heading}>Accounting destination</Text>
    <Action secondary={kind!=='expense'} title="Expense / outgoing spend" onPress={()=>setKind('expense')}/>
    <Action secondary={kind!=='incoming_payment'} title="Incoming payment evidence" onPress={()=>setKind('incoming_payment')}/>
    <TouchableOpacity onPress={()=>setConsent(v=>!v)}><Text style={styles.muted}>{consent?'☑':'☐'} I authorize transfer of this receipt to Google Cloud Vision for OCR analysis.</Text></TouchableOpacity>
    <Action title={busy?'Processing…':'Upload, OCR and submit for review'} disabled={busy||!capture||!consent} onPress={()=>void submit()}/>
   </View>}
   {screen==='review'&&<View style={styles.card}>
    <Text style={styles.heading}>Pending receipt review</Text><Text style={styles.small}>These are unposted intake candidates. A finance user must verify the vendor, amount, taxes and invoice/payment reference in the web accounting workflow.</Text>
    {intakes.map(r=><View key={r.id} style={{paddingVertical:10,borderBottomWidth:1,borderColor:'#e3e8ef'}}>
      <Text style={styles.heading}>{r.classification==='expense'?'Expense':'Incoming payment'} · {r.status}</Text>
      <Text style={styles.small}>{r.merchant_candidate||'Unknown merchant'} · {r.total_candidate==null?'Amount requires review':'$'+r.total_candidate}</Text>
    </View>)}
    {intakes.length===0&&<Text>No receipts submitted.</Text>}
    <Action secondary title="Refresh" disabled={busy} onPress={()=>void run(loadFences)}/>
   </View>}
   {!!message&&<Text style={message.startsWith('Receipt extracted')?styles.muted:styles.error}>{message}</Text>}
   {busy&&<ActivityIndicator/>}
   <Action secondary title="Sign out" onPress={()=>void supabase.auth.signOut()}/>
  </ScrollView>
 </SafeAreaView>;
}
export default App;
