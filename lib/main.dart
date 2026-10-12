import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

final GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: <String>[
    drive.DriveApi.driveReadonlyScope,
    drive.DriveApi.driveFileScope,
  ],
);

void main() {
  runApp(const GCleanApp());
}

class GCleanApp extends StatelessWidget {
  const GCleanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'G-Clean',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E5BB2),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CleanerHomePage(),
    );
  }
}

class CleanerHomePage extends StatefulWidget {
  const CleanerHomePage({super.key});

  @override
  State<CleanerHomePage> createState() => _CleanerHomePageState();
}

class _CleanerHomePageState extends State<CleanerHomePage> {
  GoogleSignInAccount? _currentUser;
  drive.DriveApi? _driveApi;
  bool _isLoading = false;
  List<drive.File> _largeFiles = [];
  int _totalBytesScanned = 0;

  @override
  void initState() {
    super.initState();
    _googleSignIn.onCurrentUserChanged.listen((account) async {
      setState(() => _currentUser = account);
      if (account != null) {
        final client = await _googleSignIn.authenticatedClient();
        if (client != null) {
          _driveApi = drive.DriveApi(client);
          _scanDrive();
        }
      } else {
        setState(() {
          _driveApi = null;
          _largeFiles = [];
          _totalBytesScanned = 0;
        });
      }
    });
    _googleSignIn.signInSilently();
  }

  Future<void> _handleSignIn() async {
    try {
      await _googleSignIn.signIn();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign-in error: $e')),
        );
      }
    }
  }

  Future<void> _handleSignOut() async {
    await _googleSignIn.disconnect();
  }

  Future<void> _scanDrive() async {
    if (_driveApi == null) return;
    setState(() => _isLoading = true);

    try {
      final fileList = await _driveApi!.files.list(
        spaces: 'drive',
        pageSize: 100,
        orderBy: 'quotaBytesUsed desc',
        q: "trashed = false and mimeType != 'application/vnd.google-apps.folder'",
        $fields: 'files(id, name, size, mimeType, modifiedTime, quotaBytesUsed)',
      );

      final files = fileList.files ?? [];
      int totalSize = 0;
      for (final f in files) {
        totalSize += int.tryParse(f.size ?? '0') ?? 0;
      }

      setState(() {
        _largeFiles = files;
        _totalBytesScanned = totalSize;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to scan Drive: $e')),
        );
      }
    }
  }

  String _formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('G-Clean'),
        actions: [
          if (_currentUser != null) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rescan Drive',
              onPressed: _isLoading ? null : _scanDrive,
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Sign Out',
              onPressed: _handleSignOut,
            ),
          ]
        ],
      ),
      body: _currentUser == null ? _buildSignInView() : _buildDashboardView(),
    );
  }

  Widget _buildSignInView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_sync, size: 80, color: Colors.blueAccent),
          const SizedBox(height: 16),
          const Text(
            'Welcome to G-Clean',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Analyze storage and identify large files on Google Drive',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _handleSignIn,
            icon: const Icon(Icons.login),
            label: const Text('Sign in with Google'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardView() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              CircleAvatar(
                backgroundImage: _currentUser?.photoUrl != null
                    ? NetworkImage(_currentUser!.photoUrl!)
                    : null,
                child: _currentUser?.photoUrl == null
                    ? const Icon(Icons.person)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentUser?.displayName ?? 'User',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _currentUser?.email ?? '',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Top Files Total', style: TextStyle(fontSize: 11)),
                  Text(
                    _formatBytes(_totalBytesScanned),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.lightBlueAccent,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_largeFiles.isEmpty)
          const Expanded(
            child: Center(child: Text('No files found or scanner is idle.')),
          )
        else
          Expanded(
            child: ListView.separated(
              itemCount: _largeFiles.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final file = _largeFiles[index];
                final sizeInt = int.tryParse(file.size ?? '0') ?? 0;
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file.name ?? 'Untitled'),
                  subtitle: Text(
                    file.mimeType ?? 'Unknown type',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    _formatBytes(sizeInt),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
