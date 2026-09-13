import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'ui/theme.dart';

void main() {
  // Storage and the audio device are opened during start-up, both of which
  // need the bindings to exist first.
  WidgetsFlutterBinding.ensureInitialized();

  // Encore is dark only, and draws its own background behind the system bars.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(EncoreTheme.systemOverlay);

  runApp(const EncoreBootstrap());
}
