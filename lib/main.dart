import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';

final GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: <String>[
    drive.DriveApi.driveScope,
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
  bool _isDeleting = false;

  Map<String, List<drive.File>> _duplicateGroups = {};
  final Set<String> _selectedFileIds = {};
  int _totalScannedBytes = 0;
  int _totalWastedBytes = 0;

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
          _duplicateGroups = {};
          _selectedFileIds.clear();
          _totalScannedBytes = 0;
          _totalWastedBytes = 0;
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
    setState(() {
      _isLoading = true;
      _selectedFileIds.clear();
    });

    try {
      final fileList = await _driveApi!.files.list(
        spaces: 'drive',
        pageSize: 500,
        orderBy: 'quotaBytesUsed desc',
        q: "trashed = false and mimeType != 'application/vnd.google-apps.folder'",
        $fields: 'files(id, name, size, mimeType, modifiedTime, quotaBytesUsed, md5Checksum)',
      );

      final files = fileList.files ?? [];
      int totalSize = 0;
      final Map<String, List<drive.File>> grouped = {};

      for (final f in files) {
        final bytes = int.tryParse(f.size ?? '0') ?? 0;
        totalSize += bytes;

        final key = (f.md5Checksum != null && f.md5Checksum!.isNotEmpty)
            ? 'hash_${f.md5Checksum}'
            : 'meta_${f.name}_${f.size}';

        grouped.putIfAbsent(key, () => []).add(f);
      }

      final Map<String, List<drive.File>> duplicates = {};
      int wasted = 0;

      grouped.forEach((k, v) {
        if (v.length > 1) {
          v.sort((a, b) => (a.modifiedTime ?? DateTime(2000))
              .compareTo(b.modifiedTime ?? DateTime(2000)));
          duplicates[k] = v;
          final individualSize = int.tryParse(v.first.size ?? '0') ?? 0;
          wasted += individualSize * (v.length - 1);
        }
      });

      setState(() {
        _duplicateGroups = duplicates;
        _totalScannedBytes = totalSize;
        _totalWastedBytes = wasted;
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

  void _autoSelectDuplicates() {
    setState(() {
      _selectedFileIds.clear();
      for (final group in _duplicateGroups.values) {
        for (int i = 1; i < group.length; i++) {
          if (group[i].id != null) {
            _selectedFileIds.add(group[i].id!);
          }
        }
      }
    });
  }

  int _calculateSelectedBytes() {
    int bytes = 0;
    for (final group in _duplicateGroups.values) {
      for (final f in group) {
        if (_selectedFileIds.contains(f.id)) {
          bytes += int.tryParse(f.size ?? '0') ?? 0;
        }
      }
    }
    return bytes;
  }

  Future<void> _trashSelectedFiles() async {
    if (_driveApi == null || _selectedFileIds.isEmpty) return;

    final count = _selectedFileIds.length;
    final spaceStr = _formatBytes(_calculateSelectedBytes());

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Drive Trash?'),
        content: Text('Move $count selected duplicate file(s) ($spaceStr) to Drive Trash? You can restore them anytime within 30 days.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isDeleting = true);

    int successCount = 0;
    for (final id in _selectedFileIds.toList()) {
      try {
        final patch = drive.File()..trashed = true;
        await _driveApi!.files.update(patch, id);
        successCount++;
      } catch (e) {
        debugPrint('Error trashing file $id: $e');
      }
    }

    setState(() => _isDeleting = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Successfully trashed $successCount file(s).')),
      );
    }
    _scanDrive();
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
        title: const Text('G-Clean Duplicate Finder'),
        actions: [
          if (_currentUser != null) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rescan',
              onPressed: _isLoading || _isDeleting ? null : _scanDrive,
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
      floatingActionButton: _selectedFileIds.isNotEmpty
          ? FloatingActionButton.extended(
              backgroundColor: Colors.redAccent,
              onPressed: _isDeleting ? null : _trashSelectedFiles,
              icon: const Icon(Icons.delete_sweep, color: Colors.white),
              label: Text(
                'Trash ${_selectedFileIds.length} Duplicate(s) (${_formatBytes(_calculateSelectedBytes())})',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            )
          : null,
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
            'Find and clean duplicate files on Google Drive',
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      '${_duplicateGroups.length} duplicate groups detected',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Wasted in Duplicates', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
                  Text(
                    _formatBytes(_totalWastedBytes),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.amberAccent,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_duplicateGroups.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton.icon(
                  onPressed: _autoSelectDuplicates,
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('Auto-Select Redundant Copies'),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedFileIds.clear()),
                  child: const Text('Clear Selection'),
                ),
              ],
            ),
          ),
        if (_isLoading || _isDeleting)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_duplicateGroups.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'No duplicate files detected across scanned items! 🎉',
                style: TextStyle(fontSize: 16),
              ),
            ),
          )
        else
          Expanded(child: _buildDuplicatesView()),
      ],
    );
  }

  Widget _buildDuplicatesView() {
    final groups = _duplicateGroups.values.toList();
    return ListView.builder(
      itemCount: groups.length,
      padding: const EdgeInsets.only(bottom: 80),
      itemBuilder: (context, index) {
        final group = groups[index];
        final sample = group.first;
        final sizeInt = int.tryParse(sample.size ?? '0') ?? 0;
        final wasted = sizeInt * (group.length - 1);

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.copy_all, color: Colors.amberAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        sample.name ?? 'Duplicate Group',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _formatBytes(sizeInt),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 32, top: 4, bottom: 8),
                  child: Text(
                    '${group.length} copies found • ${_formatBytes(wasted)} wasted storage',
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                  ),
                ),
                const Divider(height: 1),
                ...group.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final file = entry.value;
                  final isOriginal = idx == 0;
                  final isChecked = _selectedFileIds.contains(file.id);

                  return CheckboxListTile(
                    dense: true,
                    value: isChecked,
                    activeColor: Colors.redAccent,
                    onChanged: (val) {
                      setState(() {
                        if (val == true && file.id != null) {
                          _selectedFileIds.add(file.id!);
                        } else if (file.id != null) {
                          _selectedFileIds.remove(file.id!);
                        }
                      });
                    },
                    secondary: Icon(
                      isOriginal ? Icons.verified : Icons.content_copy,
                      color: isOriginal ? Colors.greenAccent : Colors.white54,
                    ),
                    title: Text(
                      file.name ?? 'Untitled',
                      style: TextStyle(
                        decoration: isChecked ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: Text(
                      '${isOriginal ? "Original (keep) • " : "Duplicate copy • "}Modified: ${file.modifiedTime != null ? file.modifiedTime!.toLocal().toString().split(".")[0] : "Unknown"}',
                      style: TextStyle(
                        fontSize: 11,
                        color: isOriginal ? Colors.greenAccent : Colors.white60,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}
