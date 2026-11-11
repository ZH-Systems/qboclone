module.exports = ({ config }) => ({
  ...config,
  name: 'Ledger North',
  slug: 'ledger-north',
  scheme: 'ledgernorth',
  version: '1.0.0',
  orientation: 'portrait',
  ios: {
    bundleIdentifier: 'com.zhsystems.ledgernorth',
    supportsTablet: true,
    infoPlist: {
      UIBackgroundModes: ['location'],
      NSLocationWhenInUseUsageDescription: 'Detect arrival at receipt reminder locations configured by your organization.',
      NSLocationAlwaysAndWhenInUseUsageDescription: 'Remind you to capture receipts after visiting organization locations, including when the app is closed.',
      NSCameraUsageDescription: 'Photograph receipts for your organization.'
    }
  },
  android: {
    package: 'com.zhsystems.ledgernorth',
    permissions: ['ACCESS_COARSE_LOCATION','ACCESS_FINE_LOCATION','ACCESS_BACKGROUND_LOCATION','POST_NOTIFICATIONS','CAMERA']
  },
  plugins: [
    ['expo-location', {
      locationAlwaysAndWhenInUsePermission: 'Remind you to capture receipts when you visit configured locations.',
      locationWhenInUsePermission: 'Identify when you enter configured receipt reminder locations.',
      isIosBackgroundLocationEnabled: true,
      isAndroidBackgroundLocationEnabled: true
    }],
    ['expo-notifications', { defaultChannel: 'receipts' }],
    'expo-image-picker'
  ],
  extra: {
    supabaseUrl: process.env.EXPO_PUBLIC_SUPABASE_URL,
    apiUrl: process.env.EXPO_PUBLIC_API_URL,
    eas: { projectId: process.env.EAS_PROJECT_ID || undefined }
  }
});
