import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/map_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );
  runApp(const NomadwiseMapsApp());
}

class NomadwiseMapsApp extends StatelessWidget {
  const NomadwiseMapsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nomadwise Maps',
      debugShowCheckedModeBanner: false,
      theme: nomadwiseTheme(),
      home: const MapScreen(),
    );
  }
}
