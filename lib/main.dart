import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_compass/flutter_compass.dart';
import 'dart:math' as math;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

// --- DATA CLASSES ---

class PrayerContext {
  final String nextPrayerName;
  final String nextPrayerTime;
  final String arabicName;

  PrayerContext({
    required this.nextPrayerName,
    required this.nextPrayerTime,
    required this.arabicName,
  });
}

class Mosque {
  final String name;
  final double lat;
  final double lon;
  double? distance;

  Mosque({
    required this.name,
    required this.lat,
    required this.lon,
    this.distance,
  });
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

// --- MAIN ENTRANCE ---

void main() {
  HttpOverrides.global = MyHttpOverrides();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mosque Finder',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        primaryColor: const Color(0xFF0E8585),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0E8585),
          primary: const Color(0xFF0E8585),
          secondary: const Color(0xFF114B3A),
          background: Colors.white,
        ),
        fontFamily: 'Roboto',
      ),
      home: const SplashScreen(),
    );
  }
}

// --- SPLASH SCREEN ---

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkPermissionsAndNavigate();
  }

  Future<void> _checkPermissionsAndNavigate() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Continue anyway
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // Initialize Notifications
    await NotificationService().init();
    await NotificationService().requestPermissions();

    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MosqueFinderShell()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E8585),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mosque, size: 80, color: Colors.white),
            ),
            const SizedBox(height: 24),
            const Text(
              "Mosque Finder",
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Find peace near you",
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 48),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

// --- MAIN SHELL (NAVIGATION) ---

class MosqueFinderShell extends StatefulWidget {
  const MosqueFinderShell({super.key});

  @override
  State<MosqueFinderShell> createState() => _MosqueFinderShellState();
}

class _MosqueFinderShellState extends State<MosqueFinderShell>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  String _currentDateKey = DateTime.now().toIso8601String().split('T')[0];

  // Prayer Logic
  String _nextPrayerName = "Loading...";
  String _nextPrayerTime = "--:--";
  String _arabicName = "";
  Position? _currentPosition;

  late List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPrayerData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Check if date changed while app was in background
      final newDateKey = DateTime.now().toIso8601String().split('T')[0];
      if (newDateKey != _currentDateKey) {
        setState(() {
          _currentDateKey = newDateKey;
          // Trigger prayer refresh potentially too
          _loadPrayerData();
        });
      }
    }
  }

  // Re-build pages when state changes
  void _updatePages() {
    final prayerContext = PrayerContext(
      nextPrayerName: _nextPrayerName,
      nextPrayerTime: _nextPrayerTime,
      arabicName: _arabicName,
    );

    _pages = [
      DashboardScreen(
        prayerContext: prayerContext,
        onTabChange: (index) => setState(() => _currentIndex = index),
      ),
      MosqueListScreen(prayerContext: prayerContext),
      const QiblaScreen(),
      const QuranResourcesScreen(),
      DailyPrayerTrackerScreen(key: ValueKey(_currentDateKey)),
    ];
  }

  Future<void> _loadPrayerData() async {
    try {
      Position position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() => _currentPosition = position);
      await _fetchNextPrayer(position.latitude, position.longitude);
    } catch (e) {
      if (mounted) {
        setState(() {
          _nextPrayerName = "Error";
          _nextPrayerTime = "Retry";
        });
      }
    }
  }

  Future<void> _fetchNextPrayer(double lat, double lng) async {
    final now = DateTime.now();
    final date = "${now.day}-${now.month}-${now.year}";
    final url = Uri.parse(
      "https://api.aladhan.com/v1/timings/$date?latitude=$lat&longitude=$lng&method=1",
    );

    try {
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final timings = data['data']['timings'];
        if (mounted) {
          _calculateNextPrayer(timings);
          // Schedule Notifications
          NotificationService().schedulePrayerReminders(timings);
        }
      }
    } catch (e) {
      debugPrint("Prayer API Error: $e");
    }
  }

  void _calculateNextPrayer(Map<String, dynamic> timings) {
    final now = DateTime.now();
    final formatter =
        "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    final prayers = ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"];
    final arabicNames = {
      "Fajr": "فجر",
      "Dhuhr": "ظهر",
      "Asr": "عصر",
      "Maghrib": "مغرب",
      "Isha": "عشاء",
    };

    for (var prayer in prayers) {
      final timeStr = timings[prayer];
      final prayerTime = DateTime.parse("$formatter $timeStr:00");

      if (prayerTime.isAfter(now)) {
        setState(() {
          _nextPrayerName = prayer;
          _arabicName = arabicNames[prayer] ?? "";
          _nextPrayerTime = _formatTime(timeStr);
        });
        return;
      }
    }

    setState(() {
      _nextPrayerName = "Fajr";
      _arabicName = "فجر";
      _nextPrayerTime = _formatTime(timings["Fajr"]);
    });
  }

  String _formatTime(String time24) {
    final parts = time24.split(':');
    int hour = int.parse(parts[0]);
    int minute = int.parse(parts[1]);
    String period = "AM";

    if (hour >= 12) {
      period = "PM";
      if (hour > 12) hour -= 12;
    }
    if (hour == 0) hour = 12;

    return "${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period";
  }

  @override
  Widget build(BuildContext context) {
    _updatePages(); // Ensure pages have latest data

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          selectedItemColor: const Color(0xFF0E8585),
          unselectedItemColor: Colors.grey[400],
          showSelectedLabels: true,
          showUnselectedLabels: true,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          elevation: 0,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_filled),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.location_on),
              label: 'Mosques',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.explore), label: 'Qibla'),
            BottomNavigationBarItem(
              icon: Icon(Icons.menu_book),
              label: 'Quran',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

class PrayerContextCard extends StatelessWidget {
  final PrayerContext prayerContext;

  const PrayerContextCard({super.key, required this.prayerContext});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
        border: Border.all(color: const Color(0xFF0E8585).withOpacity(0.1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Next Prayer at",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                prayerContext.nextPrayerTime,
                style: TextStyle(
                  fontSize: 24,
                  color: const Color(0xFF0E8585),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    prayerContext.nextPrayerName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  if (prayerContext.arabicName.isNotEmpty)
                    Text(
                      prayerContext.arabicName,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey[600],
                        fontFamily: 'Roboto',
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.mosque,
                size: 40,
                color: const Color(0xFF0E8585).withOpacity(0.6),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- 1. DASHBOARD SCREEN (HOME) ---

class DashboardScreen extends StatelessWidget {
  final PrayerContext prayerContext;
  final Function(int) onTabChange;

  const DashboardScreen({
    super.key,
    required this.prayerContext,
    required this.onTabChange,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              const Text(
                "Mosque Finder",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF114B3A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Welcome Back!",
                style: TextStyle(fontSize: 16, color: Colors.grey[600]),
              ),
              const SizedBox(height: 32),
              // PRAYER CARD
              PrayerContextCard(prayerContext: prayerContext),
              const SizedBox(height: 32),
              // MENU CARDS
              Expanded(
                child: ListView(
                  children: [
                    _buildMenuCard(
                      context,
                      title: "Find Nearby Mosque",
                      icon: Icons.location_on,
                      color: const Color(0xFF0E8585),
                      onTap: () => onTabChange(1), // Switch to Mosque Tab
                    ),
                    const SizedBox(height: 16),
                    _buildMenuCard(
                      context,
                      title: "Qibla Direction",
                      icon: Icons.explore,
                      color: const Color(0xFF2E7D6A),
                      onTap: () => onTabChange(2), // Switch to Qibla Tab
                    ),
                    const SizedBox(height: 16),
                    _buildMenuCard(
                      context,
                      title: "Quran Resources",
                      icon: Icons.menu_book,
                      color: const Color(0xFF114B3A),
                      onTap: () => onTabChange(3), // Switch to Quran Tab
                    ),
                    const SizedBox(height: 16),
                    _buildMenuCard(
                      context,
                      title: "My Progress",
                      icon: Icons.person,
                      color: const Color(0xFF0E8585),
                      onTap: () => onTabChange(4), // Switch to Profile Tab
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // HADITH OF THE DAY
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F4F8),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.withOpacity(0.2)),
                ),
                child: Column(
                  children: [
                    const Text(
                      "Hadith of the Day",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0E8585),
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "\"The best among you is the one who learns the Quran and teaches it.\"",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                        color: Colors.grey[800],
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "- Sahih Al-Bukhari",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuCard(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Container(
      width: double.infinity,
      height: 80,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.15),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 20),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF2D3142),
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 18,
                  color: Colors.grey[400],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 2. MOSQUE LIST SCREEN ---

class MosqueListScreen extends StatefulWidget {
  final PrayerContext prayerContext;
  const MosqueListScreen({super.key, required this.prayerContext});

  @override
  State<MosqueListScreen> createState() => _MosqueListScreenState();
}

class _MosqueListScreenState extends State<MosqueListScreen> {
  List<Mosque> _mosques = [];
  bool _isLoading = true;
  String _errorMessage = "";
  Mosque? _selectedMosque;

  @override
  void initState() {
    super.initState();
    _fetchNearbyMosques();
  }

  Future<void> _fetchNearbyMosques() async {
    setState(() {
      _isLoading = true;
      _errorMessage = "";
    });

    try {
      Position position = await Geolocator.getCurrentPosition();

      final query =
          """
[out:json];
(
  node["amenity"="place_of_worship"]["religion"="muslim"](around:5000,${position.latitude},${position.longitude});
  way["amenity"="place_of_worship"]["religion"="muslim"](around:5000,${position.latitude},${position.longitude});
  relation["amenity"="place_of_worship"]["religion"="muslim"](around:5000,${position.latitude},${position.longitude});
);
out center;
""";

      final url = Uri.parse("https://overpass-api.de/api/interpreter");
      final response = await http.post(
        url,
        body: query,
        headers: {
          "Accept": "application/json",
          "User-Agent": "MosqueFinderApp/1.0",
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final elements = data['elements'] as List;

        List<Mosque> fetchedMosques = [];

        for (var el in elements) {
          double lat = 0.0;
          double lon = 0.0;

          if (el['type'] == 'node') {
            lat = el['lat'];
            lon = el['lon'];
          } else if (el['center'] != null) {
            lat = el['center']['lat'];
            lon = el['center']['lon'];
          }

          if (lat != 0.0 && lon != 0.0) {
            String name = "Unnamed Mosque";
            if (el['tags'] != null) {
              if (el['tags']['name'] != null) {
                name = el['tags']['name'];
              } else if (el['tags']['name:en'] != null) {
                name = el['tags']['name:en'];
              }
            }
            fetchedMosques.add(Mosque(name: name, lat: lat, lon: lon));
          }
        }

        for (var mosque in fetchedMosques) {
          mosque.distance = Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            mosque.lat,
            mosque.lon,
          );
        }

        fetchedMosques.sort(
          (a, b) => (a.distance ?? 0).compareTo(b.distance ?? 0),
        );

        if (mounted) {
          setState(() {
            _mosques = fetchedMosques;
            _isLoading = false;
            if (_mosques.isNotEmpty) {
              _selectedMosque = _mosques.first;
            }
          });
        }

        if (fetchedMosques.isEmpty && mounted) {
          setState(() {
            _errorMessage = "No mosques found nearby (5km radius).";
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = "Failed to load: Status ${response.statusCode}";
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = "Error: $e";
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _navigateToSelected() async {
    if (_selectedMosque == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("No mosque selected.")));
      return;
    }
    final target = _selectedMosque!;
    final Uri url = Uri.parse(
      "https://www.google.com/maps/dir/?api=1&destination=${target.lat},${target.lon}",
    );
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        await launchUrl(url);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Could not launch maps.")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F4F8),
      appBar: AppBar(
        title: const Text("Nearby Mosques"),
        backgroundColor: const Color(0xFF0E8585),
        elevation: 0,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchNearbyMosques,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: PrayerContextCard(prayerContext: widget.prayerContext),
            ),
            if (!_isLoading && _mosques.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Found ${_mosques.length} mosques. Tap to select.",
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _errorMessage.isNotEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            size: 48,
                            color: Colors.redAccent,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _errorMessage,
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _fetchNearbyMosques,
                            icon: const Icon(Icons.refresh),
                            label: const Text("Retry"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0E8585),
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      itemCount: _mosques.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final mosque = _mosques[index];
                        final isNearest = index == 0;
                        final isSelected = _selectedMosque == mosque;

                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedMosque = mosque;
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF0E8585).withOpacity(0.05)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.04),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                              border: isSelected
                                  ? Border.all(
                                      color: const Color(0xFF0E8585),
                                      width: 2.0,
                                    )
                                  : null,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? const Color(0xFF0E8585)
                                          : const Color(0xFFF2F4F8),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      Icons.mosque_outlined,
                                      color: isSelected
                                          ? Colors.white
                                          : const Color(0xFF0E8585),
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                mosque.name,
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                  color: isSelected
                                                      ? const Color(0xFF0E8585)
                                                      : Colors.black87,
                                                ),
                                                softWrap: true,
                                              ),
                                            ),
                                            if (isNearest)
                                              Container(
                                                margin: const EdgeInsets.only(
                                                  left: 8,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFF2E7D6A,
                                                  ).withOpacity(0.1),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                child: const Text(
                                                  "Nearest",
                                                  style: TextStyle(
                                                    color: Color(0xFF114B3A),
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.location_on,
                                              size: 14,
                                              color: Colors.grey[500],
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              mosque.distance != null
                                                  ? "${(mosque.distance! / 1000).toStringAsFixed(2)} km away"
                                                  : "Calculating...",
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: Colors.grey[600],
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 8),
                                      child: Icon(
                                        Icons.check_circle,
                                        color: Color(0xFF0E8585),
                                        size: 24,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: () => _navigateToSelected(),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0E8585),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              _selectedMosque != null
                  ? "Navigate to ${_selectedMosque!.name}"
                  : "Select a Mosque",
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}

// --- 3. QIBLA SCREEN ---

class QiblaScreen extends StatefulWidget {
  const QiblaScreen({super.key});

  @override
  State<QiblaScreen> createState() => _QiblaScreenState();
}

class _QiblaScreenState extends State<QiblaScreen> {
  double? _direction;
  double _qiblaDirection = 0;
  bool _hasPermissions = false;

  @override
  void initState() {
    super.initState();
    _checkLocationPermission();
  }

  Future<void> _checkLocationPermission() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      final requested = await Geolocator.requestPermission();
      if (requested == LocationPermission.denied) {
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      return;
    }

    if (mounted) {
      setState(() => _hasPermissions = true);
    }
    _calculateQibla();

    FlutterCompass.events?.listen((event) {
      if (mounted) {
        setState(() {
          _direction = event.heading;
        });
      }
    });
  }

  Future<void> _calculateQibla() async {
    final position = await Geolocator.getCurrentPosition();
    final lat = position.latitude;
    final lng = position.longitude;

    // Kaaba coordinates
    const kaabaLat = 21.4225;
    const kaabaLng = 39.8262;

    final y = math.sin(math.pi * (kaabaLng - lng) / 180);
    final x =
        math.cos(math.pi * lat / 180) * math.tan(math.pi * kaabaLat / 180) -
        math.sin(math.pi * lat / 180) *
            math.cos(math.pi * (kaabaLng - lng) / 180);

    final qibla = math.atan2(y, x) * 180 / math.pi;
    if (mounted) {
      setState(() {
        _qiblaDirection = (qibla + 360) % 360;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F4F8),
      appBar: AppBar(
        title: const Text("Qibla Direction"),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0E8585),
        elevation: 0,
      ),
      body: !_hasPermissions
          ? const Center(child: Text("Location permission required"))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "${_qiblaDirection.toStringAsFixed(0)}°",
                  style: const TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0E8585),
                  ),
                ),
                const Text(
                  "Qibla Direction",
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
                const SizedBox(height: 50),
                Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 300,
                        height: 300,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                          border: Border.all(
                            color: Colors.grey.withOpacity(0.2),
                            width: 2,
                          ),
                        ),
                        child: CustomPaint(painter: CompassPainter()),
                      ),
                      Transform.rotate(
                        angle: ((_direction ?? 0) * (math.pi / 180) * -1),
                        child: SizedBox(
                          width: 300,
                          height: 300,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Positioned(
                                top: 20,
                                child: Text(
                                  "N",
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red[400],
                                  ),
                                ),
                              ),
                              Transform.rotate(
                                angle: (_qiblaDirection * (math.pi / 180)),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.mosque,
                                      size: 32,
                                      color: Color(0xFF0E8585),
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      width: 6,
                                      height: 100,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0E8585),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                    const SizedBox(height: 100),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 50),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    "Keep your phone flat for accurate results.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
    );
  }
}

class CompassPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final paint = Paint()
      ..color = Colors.grey.withOpacity(0.3)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < 360; i += 30) {
      final angle = i * math.pi / 180;
      final start = Offset(
        center.dx + (radius - 15) * math.cos(angle),
        center.dy + (radius - 15) * math.sin(angle),
      );
      final end = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- NOTIFICATION SERVICE ---

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    try {
      tz.initializeTimeZones();
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const InitializationSettings initializationSettings =
          InitializationSettings(android: initializationSettingsAndroid);

      await flutterLocalNotificationsPlugin.initialize(initializationSettings);
    } catch (e) {
      debugPrint("Notification Init Error: $e");
    }
  }

  Future<void> requestPermissions() async {
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint("Permission Error: $e");
    }
  }

  Future<void> schedulePrayerReminders(Map<String, dynamic> timings) async {
    try {
      await flutterLocalNotificationsPlugin.cancelAll();
    } catch (e) {
      debugPrint("Error canceling notifications: $e");
    }

    final now = DateTime.now();
    final prayers = ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"];
    int id = 0;

    for (var prayer in prayers) {
      final timeStr = timings[prayer];
      if (timeStr == null || timeStr is! String) continue;

      final cleanTime = timeStr.split(' ')[0];
      final parts = cleanTime.split(':');
      if (parts.length < 2) continue;

      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);

      final prayerDateTimeLocal = DateTime(
        now.year,
        now.month,
        now.day,
        hour,
        minute,
      );

      // Reminder 1: 20 mins before
      final reminder20 = prayerDateTimeLocal.subtract(
        const Duration(minutes: 20),
      );
      if (reminder20.isAfter(now)) {
        await _scheduleNotification(
          id++,
          "$prayer in 20 minutes. Prepare for Salah.",
          reminder20,
        );
      }

      // Reminder 2: 10 mins before
      final reminder10 = prayerDateTimeLocal.subtract(
        const Duration(minutes: 10),
      );
      if (reminder10.isAfter(now)) {
        await _scheduleNotification(
          id++,
          "Hurry up. $prayer Jamaat is about to start.",
          reminder10,
        );
      }
    }
  }

  Future<void> _scheduleNotification(
    int id,
    String body,
    DateTime scheduledTime,
  ) async {
    try {
      final scheduledTZ = tz.TZDateTime.from(scheduledTime.toUtc(), tz.UTC);

      await flutterLocalNotificationsPlugin.zonedSchedule(
        id,
        'Prayer Reminder', // title
        body,
        scheduledTZ,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'prayer_channel',
            'Prayer Reminders',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: 'prayer_reminder',
      );
      debugPrint("Scheduled: $body at $scheduledTime");
    } catch (e) {
      debugPrint("Error scheduling notification: $e");
    }
  }
}

// --- 4. QURAN RESOURCES SCREEN ---

class QuranResourcesScreen extends StatelessWidget {
  const QuranResourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2F1), // Soft green
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Quran Resources",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00695C),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Read, Listen, and Reflect",
                      style: TextStyle(fontSize: 16, color: Colors.grey[700]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Section 1: Read Quran
              const Text(
                "📖 Read Quran",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF114B3A),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 100,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: const [
                    _QuranCard(title: "Surah Yaseen"),
                    _QuranCard(title: "Surah Rahman"),
                    _QuranCard(title: "Surah Mulk"),
                    _QuranCard(title: "Surah Kahf"),
                    _QuranCard(title: "Surah Ikhlas"),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Section 2: Listen to Recitation
              const Text(
                "🎧 Listen to Recitation",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF114B3A),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: ListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: const [
                    _ReciterTile(
                      name: "Mishary Rashid",
                      icon: Icons.play_circle_fill,
                    ),
                    Divider(height: 1),
                    _ReciterTile(name: "Sudais", icon: Icons.play_circle_fill),
                    Divider(height: 1),
                    _ReciterTile(
                      name: "Abdul Basit",
                      icon: Icons.play_circle_fill,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Section 3: Daily Hadith
              const Text(
                "📚 Daily Hadith",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF114B3A),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F4F8),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Abu Huraira reported: The Messenger of Allah, peace and blessings be upon him, said:",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      "\"When a man dies, his deeds come to an end except for three things: Sadaqah Jariyah (ceaseless charity); a knowledge which is beneficial, or a virtuous descendant who prays for him.\"",
                      style: TextStyle(
                        fontSize: 16,
                        color: Color(0xFF2D3142),
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuranCard extends StatelessWidget {
  final String title;
  const _QuranCard({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: const Color(0xFF0E8585).withOpacity(0.1)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.menu_book, color: Color(0xFF0E8585), size: 32),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Color(0xFF114B3A),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReciterTile extends StatelessWidget {
  final String name;
  final IconData icon;
  const _ReciterTile({required this.name, required this.icon});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFE0F2F1),
        child: Icon(Icons.person, color: const Color(0xFF00695C)),
      ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Icon(icon, color: const Color(0xFF0E8585)),
      onTap: () {
        // Placeholder action
      },
    );
  }
}

// --- 5. DAILY PRAYER TRACKER SCREEN (PROFILE) ---

class DailyPrayerTrackerScreen extends StatefulWidget {
  const DailyPrayerTrackerScreen({super.key});

  @override
  State<DailyPrayerTrackerScreen> createState() =>
      _DailyPrayerTrackerScreenState();
}

class _DailyPrayerTrackerScreenState extends State<DailyPrayerTrackerScreen> {
  final List<String> _prayers = ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"];
  Map<String, bool> _completed = {
    "Fajr": false,
    "Dhuhr": false,
    "Asr": false,
    "Maghrib": false,
    "Isha": false,
  };
  int _completedCount = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();

    // Check Date Reset
    final String today = DateTime.now().toIso8601String().split('T')[0];
    final String? lastSavedDate = prefs.getString('tracker_date');

    if (lastSavedDate != today) {
      // New Day: Reset only tracker keys
      for (var p in _prayers) {
        await prefs.remove('tracker_$p');
      }
      await prefs.setString('tracker_date', today);
    }

    // Load Checks
    int count = 0;
    for (var p in _prayers) {
      bool isDone = prefs.getBool('tracker_$p') ?? false;
      _completed[p] = isDone;
      if (isDone) count++;
    }

    if (mounted) {
      setState(() {
        _completedCount = count;
        _isLoading = false;
      });
    }
  }

  Future<void> _togglePrayer(String prayer) async {
    final prefs = await SharedPreferences.getInstance();
    bool currentVal = _completed[prayer] ?? false;
    bool newVal = !currentVal;

    setState(() {
      _completed[prayer] = newVal;
      _completedCount += newVal ? 1 : -1;
    });

    await prefs.setBool('tracker_$prayer', newVal);
  }

  @override
  Widget build(BuildContext context) {
    final double percentage = _completedCount / 5;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Today's Prayer Tracker"),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF114B3A),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    // Summary Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF0E8585), Color(0xFF114B3A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0E8585).withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Text(
                            "$_completedCount / 5 Prayers Completed",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: percentage,
                              backgroundColor: Colors.white.withOpacity(0.2),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                              minHeight: 10,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _completedCount == 5
                                ? "Alhamdulillah! All prayers completed today."
                                : "Stay consistent. Complete today's prayers.",
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Checklist
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _prayers.length,
                      itemBuilder: (context, index) {
                        final prayer = _prayers[index];
                        final isCompleted = _completed[prayer] ?? false;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: isCompleted
                                ? const Color(0xFFE0F2F1)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isCompleted
                                  ? const Color(0xFF0E8585)
                                  : Colors.grey[200]!,
                            ),
                          ),
                          child: CheckboxListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            title: Text(
                              prayer,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isCompleted
                                    ? const Color(0xFF00695C)
                                    : Colors.black87,
                                decoration: isCompleted
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            secondary: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isCompleted
                                    ? const Color(0xFF0E8585)
                                    : Colors.grey[100],
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isCompleted ? Icons.check : Icons.access_time,
                                color: isCompleted ? Colors.white : Colors.grey,
                                size: 20,
                              ),
                            ),
                            value: isCompleted,
                            activeColor: const Color(0xFF0E8585),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            onChanged: (val) => _togglePrayer(prayer),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
