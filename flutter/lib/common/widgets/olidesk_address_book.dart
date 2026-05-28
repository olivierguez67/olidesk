import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http_svc;

// ---------------------------------------------------------------------------
// Config keys
// ---------------------------------------------------------------------------

const _kApiUrlKey = 'olidesk-ab-api-url';
const _kTokenKey = 'olidesk-ab-token';
const _kDefaultApiUrl = 'http://172.104.159.65:8443';

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

class _AbGroup {
  final int id;
  final String name;
  final int? parentId;
  final List<_AbGroup> children;

  _AbGroup({
    required this.id,
    required this.name,
    this.parentId,
    List<_AbGroup>? children,
  }) : children = children ?? [];

  static _AbGroup fromJson(Map<String, dynamic> j) => _AbGroup(
        id: j['id'] as int,
        name: j['name'] as String? ?? '',
        parentId: j['parent_id'] as int?,
        children: (j['children'] as List? ?? [])
            .map((c) => _AbGroup.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

class _AbClient {
  final int id;
  final String olideskId;
  final String name;
  final int? groupId;
  final String? groupName;
  final String? hostname;
  final String? platform;
  final String? notes;
  final String? lastSeen;

  _AbClient.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        olideskId = j['olidesk_id'] as String? ?? '',
        name = j['name'] as String? ?? '',
        groupId = j['group_id'] as int?,
        groupName = j['group_name'] as String?,
        hostname = j['hostname'] as String?,
        platform = j['platform'] as String?,
        notes = j['notes'] as String?,
        lastSeen = j['last_seen'] as String?;
}

// ---------------------------------------------------------------------------
// Tree helpers
// ---------------------------------------------------------------------------

class _FlatGroup {
  final _AbGroup group;
  final int depth;
  _FlatGroup(this.group, this.depth);
}

/// All groups, depth-first, regardless of expansion state (for dropdowns).
List<_FlatGroup> _flattenAll(List<_AbGroup> roots, [int depth = 0]) {
  final out = <_FlatGroup>[];
  for (final g in roots) {
    out.add(_FlatGroup(g, depth));
    out.addAll(_flattenAll(g.children, depth + 1));
  }
  return out;
}

/// Only groups whose ancestors are all expanded (for the tree view).
List<_FlatGroup> _flattenVisible(
    List<_AbGroup> roots, Set<int> expanded, [int depth = 0]) {
  final out = <_FlatGroup>[];
  for (final g in roots) {
    out.add(_FlatGroup(g, depth));
    if (expanded.contains(g.id) && g.children.isNotEmpty) {
      out.addAll(_flattenVisible(g.children, expanded, depth + 1));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

class OlideskAddressBook extends StatefulWidget {
  const OlideskAddressBook({Key? key}) : super(key: key);

  @override
  State<OlideskAddressBook> createState() => _OlideskAddressBookState();
}

class _OlideskAddressBookState extends State<OlideskAddressBook> {
  final _groups = <_AbGroup>[].obs;
  final _clients = <_AbClient>[].obs;
  final _selectedGroupId = Rx<int?>(null);
  final _loading = false.obs;
  final _error = ''.obs;

  // Expansion state for the tree view (not reactive — toggled via _treeVer).
  final Set<int> _expanded = {};
  // Bump to force Obx tree rebuild after expanding/collapsing.
  final _treeVer = 0.obs;

  // Captured pointer position for context menu.
  RelativeRect _menuPos = RelativeRect.fromLTRB(0, 0, 0, 0);

  // ---------------------------------------------------------------------------
  // Config accessors
  // ---------------------------------------------------------------------------

  String get _apiUrl {
    final v = bind.mainGetLocalOption(key: _kApiUrlKey);
    return v.isNotEmpty ? v : _kDefaultApiUrl;
  }

  String get _token => bind.mainGetLocalOption(key: _kTokenKey);

  bool get _isConfigured => _token.isNotEmpty;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
      };

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    if (_isConfigured) _load();
  }

  // ---------------------------------------------------------------------------
  // API
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    _loading.value = true;
    _error.value = '';
    try {
      await Future.wait([_fetchGroups(), _fetchClients()]);
    } catch (e) {
      _error.value = _friendlyError(e);
    } finally {
      _loading.value = false;
    }
  }

  Future<void> _fetchGroups() async {
    try {
      final resp = await http_svc
          .get(Uri.parse('$_apiUrl/api/groups'), headers: _headers)
          .timeout(const Duration(seconds: 10),
              onTimeout: () =>
                  throw TimeoutException('Request timed out after 10 s'));
      _handleStatus(resp.statusCode);
      final data = jsonDecode(resp.body) as List;
      _groups.value =
          data.map((g) => _AbGroup.fromJson(g as Map<String, dynamic>)).toList();
      // Auto-expand top-level groups on first load.
      if (_expanded.isEmpty) {
        for (final g in _groups) {
          _expanded.add(g.id);
        }
      }
      _treeVer.value++;
    } catch (e) {
      _error.value = _friendlyError(e);
      rethrow;
    }
  }

  Future<void> _fetchClients({int? groupId}) async {
    try {
      final url = groupId != null
          ? '$_apiUrl/api/clients?group_id=$groupId'
          : '$_apiUrl/api/clients';
      final resp = await http_svc
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 10),
              onTimeout: () =>
                  throw TimeoutException('Request timed out after 10 s'));
      _handleStatus(resp.statusCode);
      final data = jsonDecode(resp.body) as List;
      _clients.value = data
          .map((c) => _AbClient.fromJson(c as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _error.value = _friendlyError(e);
      rethrow;
    }
  }

  Future<void> _apiDeleteClient(int id) async {
    await http_svc.delete(Uri.parse('$_apiUrl/api/clients/$id'),
        headers: _headers);
    await _fetchClients(groupId: _selectedGroupId.value);
  }

  Future<void> _apiDeleteGroup(int id) async {
    await http_svc
        .delete(Uri.parse('$_apiUrl/api/groups/$id'), headers: _headers)
        .timeout(const Duration(seconds: 10),
            onTimeout: () =>
                throw TimeoutException('Request timed out after 10 s'));
    if (_selectedGroupId.value == id) _selectedGroupId.value = null;
    await _fetchGroups();
    await _fetchClients(groupId: _selectedGroupId.value);
  }

  Future<void> _apiMoveClient(int id, int? groupId) async {
    await http_svc.post(
      Uri.parse('$_apiUrl/api/clients/$id/move'),
      headers: _headers,
      body: jsonEncode({'group_id': groupId}),
    );
    await _fetchClients(groupId: _selectedGroupId.value);
  }

  void _handleStatus(int code) {
    if (code == 401) throw Exception('Unauthorized — check API token');
    if (code == 403) throw Exception('Forbidden');
    if (code >= 500) throw Exception('Server error ($code)');
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (e is TimeoutException || msg.contains('timed out')) {
      return 'Connection timed out.\nCheck that the API server is running and reachable.';
    }
    if (msg.contains('Connection refused') ||
        msg.contains('SocketException') ||
        msg.contains('Failed host')) {
      return 'Cannot reach API server.\nCheck URL in address book settings.';
    }
    return msg.replaceFirst('Exception: ', '');
  }

  List<_AbClient> get _visibleClients {
    final gid = _selectedGroupId.value;
    if (gid == null) return _clients;
    return _clients.where((c) => c.groupId == gid).toList();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(context),
        const Divider(height: 1),
        Expanded(
          child: Obx(() {
            if (!_isConfigured) return _buildUnconfigured(context);
            if (_error.value.isNotEmpty) {
              return _buildError(context);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 210, child: _buildGroupPanel(context)),
                const VerticalDivider(width: 1),
                Expanded(child: _buildClientPanel(context)),
              ],
            );
          }),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Toolbar
  // ---------------------------------------------------------------------------

  Widget _buildToolbar(BuildContext context) {
    final iconColor = Theme.of(context).textTheme.bodyMedium?.color;
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Obx(() => _loading.value
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _toolbarBtn(
                    icon: Icons.refresh,
                    tooltip: translate('Refresh'),
                    onTap: _load,
                    color: iconColor,
                  )),
            const SizedBox(width: 6),
            _toolbarTextBtn(
              icon: Icons.create_new_folder_outlined,
              label: 'Add Group',
              onTap: () {
                if (!_isConfigured) {
                  _showSettingsDialog(context);
                } else {
                  _showAddGroupDialog(context);
                }
              },
            ),
            const SizedBox(width: 4),
            _toolbarTextBtn(
              icon: Icons.person_add_alt_1_outlined,
              label: 'Add Client',
              onTap: () {
                if (!_isConfigured) {
                  _showSettingsDialog(context);
                } else {
                  _showAddClientDialog(context);
                }
              },
            ),
            const Spacer(),
            _toolbarBtn(
              icon: Icons.settings_outlined,
              tooltip: 'Address Book Settings',
              onTap: () => _showSettingsDialog(context),
              color: iconColor,
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbarBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }

  Widget _toolbarTextBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return TextButton.icon(
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // States: unconfigured / error
  // ---------------------------------------------------------------------------

  Widget _buildUnconfigured(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings_ethernet,
                size: 52, color: Theme.of(context).hintColor),
            const SizedBox(height: 14),
            Text('Address book not configured.',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('Click Configure to enter your API URL and bearer token.',
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('Configure'),
              onPressed: () => _showSettingsDialog(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48, color: Colors.redAccent),
          const SizedBox(height: 12),
          Obx(() => Text(
                _error.value,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              )),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: _load,
                child: Text(translate('Retry')),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('Settings'),
                onPressed: () => _showSettingsDialog(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Group tree panel (left)
  // ---------------------------------------------------------------------------

  Widget _buildGroupPanel(BuildContext context) {
    return Obx(() {
      _treeVer.value; // dependency — rebuilt on expand/collapse
      final flat = _flattenVisible(_groups, _expanded);
      return ListView(
        children: [
          _buildGroupTile(
            context,
            icon: Icons.people_outline,
            label: translate('All'),
            isSelected: _selectedGroupId.value == null,
            depth: 0,
            onTap: () {
              _selectedGroupId.value = null;
              _fetchClients();
            },
          ),
          const Divider(height: 1, indent: 8, endIndent: 8),
          ...flat.map((fg) => _buildGroupTreeTile(context, fg)),
        ],
      );
    });
  }

  Widget _buildGroupTreeTile(BuildContext context, _FlatGroup fg) {
    final g = fg.group;
    final hasChildren = g.children.isNotEmpty;
    final isExpanded = _expanded.contains(g.id);
    final hover = false.obs;

    void doTap() {
      if (hasChildren) {
        if (_expanded.contains(g.id)) {
          _expanded.remove(g.id);
        } else {
          _expanded.add(g.id);
        }
        _treeVer.value++;
      }
      _selectedGroupId.value = g.id;
      _fetchClients(groupId: g.id);
    }

    void showGroupMenu() {
      final RenderBox box = context.findRenderObject() as RenderBox;
      final offset = box.localToGlobal(Offset.zero);
      showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
            _menuPos.left, _menuPos.top, _menuPos.right, _menuPos.bottom),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        items: [
          PopupMenuItem(
            value: 'delete',
            child: _menuItem(Icons.delete_outline, translate('Delete'),
                color: Colors.redAccent),
          ),
        ],
        elevation: 6,
      ).then((action) {
        if (!mounted || action == null) return;
        if (action == 'delete') _confirmDeleteGroup(context, g);
      });
    }

    return Listener(
      onPointerDown: (e) {
        final x = e.position.dx;
        final y = e.position.dy;
        _menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      child: MouseRegion(
        onEnter: (_) => hover.value = true,
        onExit: (_) => hover.value = false,
        child: GestureDetector(
          onSecondaryTap: showGroupMenu,
          child: _buildGroupTile(
            context,
            icon: hasChildren
                ? (isExpanded ? Icons.folder_open : Icons.folder)
                : Icons.folder_outlined,
            iconColor: MyTheme.accent,
            label: g.name,
            isSelected: _selectedGroupId.value == g.id,
            depth: fg.depth,
            trailing: Obx(() => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasChildren)
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: Theme.of(context).hintColor,
                      ),
                    if (hover.value)
                      InkWell(
                        onTap: showGroupMenu,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(Icons.more_vert,
                              size: 14,
                              color: Theme.of(context).hintColor),
                        ),
                      ),
                  ],
                )),
            onTap: doTap,
          ),
        ),
      ),
    );
  }

  Widget _buildGroupTile(
    BuildContext context, {
    required IconData icon,
    Color? iconColor,
    required String label,
    required bool isSelected,
    required int depth,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return Material(
      color: isSelected
          ? MyTheme.accent.withOpacity(0.12)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(
            left: 12.0 + depth * 14.0,
            right: 8,
            top: 6,
            bottom: 6,
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Client list panel (right)
  // ---------------------------------------------------------------------------

  Widget _buildClientPanel(BuildContext context) {
    return Obx(() {
      final clients = _visibleClients;
      if (_loading.value && clients.isEmpty) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (clients.isEmpty) {
        return Center(
          child: Text(
            translate('No clients'),
            style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13),
          ),
        );
      }
      return ListView.separated(
        itemCount: clients.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, indent: 52, endIndent: 8),
        itemBuilder: (ctx, i) => _buildClientRow(ctx, clients[i]),
      );
    });
  }

  Widget _buildClientRow(BuildContext context, _AbClient client) {
    return Listener(
      onPointerDown: (e) {
        final x = e.position.dx;
        final y = e.position.dy;
        _menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      child: GestureDetector(
        onDoubleTap: () => _connect(context, client),
        onSecondaryTap: () => _showContextMenu(context, client),
        child: ListTile(
          leading: _platformIcon(client.platform),
          title: Text(
            client.name,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Row(
            children: [
              Text(
                client.olideskId,
                style: TextStyle(
                  fontSize: 12,
                  color: MyTheme.accent,
                  fontFamily: 'monospace',
                ),
              ),
              if (client.hostname != null && client.hostname!.isNotEmpty) ...[
                Text(
                  '  ·  ${client.hostname}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ],
          ),
          trailing: IconButton(
            icon: Icon(Icons.more_vert,
                size: 18, color: Theme.of(context).hintColor),
            onPressed: () => _showContextMenu(context, client),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          onTap: () {},
        ),
      ),
    );
  }

  Widget _platformIcon(String? platform) {
    final p = (platform ?? '').toLowerCase();
    if (p.contains('windows')) {
      return const Icon(Icons.computer, size: 26, color: Colors.blueAccent);
    } else if (p.contains('mac') || p.contains('osx')) {
      return const Icon(Icons.laptop_mac, size: 26, color: Colors.grey);
    } else if (p.contains('android')) {
      return const Icon(Icons.phone_android, size: 26, color: Colors.green);
    } else if (p.contains('linux')) {
      return const Icon(Icons.terminal, size: 26, color: Colors.orange);
    } else if (p.contains('ios')) {
      return const Icon(Icons.phone_iphone, size: 26, color: Colors.blueGrey);
    }
    return const Icon(Icons.devices_other, size: 26, color: Colors.grey);
  }

  // ---------------------------------------------------------------------------
  // Connect
  // ---------------------------------------------------------------------------

  void _connect(BuildContext context, _AbClient client) {
    if (client.olideskId.isEmpty) return;
    connect(context, client.olideskId);
  }

  // ---------------------------------------------------------------------------
  // Context menu
  // ---------------------------------------------------------------------------

  void _showContextMenu(BuildContext context, _AbClient client) {
    showMenu<String>(
      context: context,
      position: _menuPos,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        PopupMenuItem(
          value: 'connect',
          child: _menuItem(Icons.play_circle_outline, translate('Connect')),
        ),
        PopupMenuItem(
          value: 'edit',
          child: _menuItem(Icons.edit_outlined, translate('Edit')),
        ),
        PopupMenuItem(
          value: 'move',
          child: _menuItem(Icons.drive_file_move_outlined, 'Move to Group'),
        ),
        const PopupMenuDivider(height: 4),
        PopupMenuItem(
          value: 'delete',
          child: _menuItem(Icons.delete_outline, translate('Delete'),
              color: Colors.redAccent),
        ),
      ],
      elevation: 6,
    ).then((action) {
      if (!mounted || action == null) return;
      switch (action) {
        case 'connect':
          _connect(context, client);
          break;
        case 'edit':
          _showEditClientDialog(context, client);
          break;
        case 'move':
          _showMoveDialog(context, client);
          break;
        case 'delete':
          _confirmDelete(context, client);
          break;
      }
    });
  }

  Widget _menuItem(IconData icon, String label, {Color? color}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13, color: color)),
      ],
    );
  }

  void _confirmDelete(BuildContext context, _AbClient client) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(translate('Delete')),
        content: Text('Remove "${client.name}" from address book?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(translate('Cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _apiDeleteClient(client.id);
              } catch (e) {
                _error.value = _friendlyError(e);
              }
            },
            child: Text(translate('Delete')),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteGroup(BuildContext context, _AbGroup group) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(translate('Delete')),
        content: Text(
            'Delete group "${group.name}"? Clients in this group will be unassigned.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(translate('Cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _apiDeleteGroup(group.id);
              } catch (e) {
                _error.value = _friendlyError(e);
              }
            },
            child: Text(translate('Delete')),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  void _showSettingsDialog(BuildContext context) {
    final urlCtrl = TextEditingController(text: _apiUrl);
    final tokenCtrl = TextEditingController(text: _token);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Address Book API Settings'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'API URL',
                  hintText: _kDefaultApiUrl,
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: tokenCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Bearer Token',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(translate('Cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              await bind.mainSetLocalOption(
                  key: _kApiUrlKey, value: urlCtrl.text.trim());
              await bind.mainSetLocalOption(
                  key: _kTokenKey, value: tokenCtrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              _load();
            },
            child: Text(translate('Save')),
          ),
        ],
      ),
    );
  }

  void _showAddGroupDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    int? parentId;
    final allFlat = _flattenAll(_groups);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Add Group'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: translate('Name'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<int?>(
                  value: parentId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Parent group (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('None (top level)')),
                    ...allFlat.map((fg) => DropdownMenuItem(
                          value: fg.group.id,
                          child: Text(
                            '${'  ' * fg.depth}${fg.group.name}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        )),
                  ],
                  onChanged: (v) => setDlg(() => parentId = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(translate('Cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx);
                try {
                  await http_svc.post(
                    Uri.parse('$_apiUrl/api/groups'),
                    headers: _headers,
                    body: jsonEncode({'name': name, 'parent_id': parentId}),
                  );
                  await _fetchGroups();
                } catch (e) {
                  _error.value = _friendlyError(e);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddClientDialog(BuildContext context) {
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final hostnameCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    int? groupId = _selectedGroupId.value;
    String? platform;
    final allFlat = _flattenAll(_groups);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Add Client'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: idCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Olidesk ID *',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: '${translate('Name')} *',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: hostnameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Hostname',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    value: platform,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Platform',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('Unknown')),
                      ...['Windows', 'macOS', 'Linux', 'Android', 'iOS']
                          .map((p) =>
                              DropdownMenuItem(value: p, child: Text(p))),
                    ],
                    onChanged: (v) => setDlg(() => platform = v),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int?>(
                    value: groupId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Group',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('No group')),
                      ...allFlat.map((fg) => DropdownMenuItem(
                            value: fg.group.id,
                            child: Text(
                              '${'  ' * fg.depth}${fg.group.name}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          )),
                    ],
                    onChanged: (v) => setDlg(() => groupId = v),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: translate('Notes'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(translate('Cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final id = idCtrl.text.trim();
                final name = nameCtrl.text.trim();
                if (id.isEmpty || name.isEmpty) return;
                Navigator.pop(ctx);
                try {
                  await http_svc.post(
                    Uri.parse('$_apiUrl/api/clients'),
                    headers: _headers,
                    body: jsonEncode({
                      'olidesk_id': id,
                      'name': name,
                      'group_id': groupId,
                      if (hostnameCtrl.text.trim().isNotEmpty)
                        'hostname': hostnameCtrl.text.trim(),
                      if (platform != null) 'platform': platform,
                      if (notesCtrl.text.trim().isNotEmpty)
                        'notes': notesCtrl.text.trim(),
                    }),
                  );
                  await _fetchClients(groupId: _selectedGroupId.value);
                } catch (e) {
                  _error.value = _friendlyError(e);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditClientDialog(BuildContext context, _AbClient client) {
    final nameCtrl = TextEditingController(text: client.name);
    final hostnameCtrl = TextEditingController(text: client.hostname ?? '');
    final notesCtrl = TextEditingController(text: client.notes ?? '');
    String? platform = client.platform;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(translate('Edit')),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: translate('Name'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: hostnameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Hostname',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    value: platform,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Platform',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('Unknown')),
                      ...['Windows', 'macOS', 'Linux', 'Android', 'iOS']
                          .map((p) =>
                              DropdownMenuItem(value: p, child: Text(p))),
                    ],
                    onChanged: (v) => setDlg(() => platform = v),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: translate('Notes'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(translate('Cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx);
                await http_svc.put(
                  Uri.parse('$_apiUrl/api/clients/${client.id}'),
                  headers: _headers,
                  body: jsonEncode({
                    'name': name,
                    'hostname': hostnameCtrl.text.trim().isEmpty
                        ? null
                        : hostnameCtrl.text.trim(),
                    'platform': platform,
                    'notes': notesCtrl.text.trim().isEmpty
                        ? null
                        : notesCtrl.text.trim(),
                  }),
                );
                await _fetchClients(groupId: _selectedGroupId.value);
              },
              child: Text(translate('Save')),
            ),
          ],
        ),
      ),
    );
  }

  void _showMoveDialog(BuildContext context, _AbClient client) {
    int? targetGroupId = client.groupId;
    final allFlat = _flattenAll(_groups);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Move to Group'),
          content: SizedBox(
            width: 320,
            child: DropdownButtonFormField<int?>(
              value: targetGroupId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Target group',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('No group')),
                ...allFlat.map((fg) => DropdownMenuItem(
                      value: fg.group.id,
                      child: Text(
                        '${'  ' * fg.depth}${fg.group.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    )),
              ],
              onChanged: (v) => setDlg(() => targetGroupId = v),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(translate('Cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  await _apiMoveClient(client.id, targetGroupId);
                } catch (e) {
                  _error.value = _friendlyError(e);
                }
              },
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );
  }
}
