import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'internal/barrio/screens/barrio_home_screen.dart';

class BarrioApp extends StatelessWidget {
  const BarrioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Barrio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: const BarrioHomeScreen(),
    );
  }
}
