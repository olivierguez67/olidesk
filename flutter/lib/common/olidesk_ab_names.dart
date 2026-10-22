import 'dart:convert';

import 'package:get/get.dart';

import '../models/platform_model.dart';

// Address-book names by Olidesk ID, so peer cards outside the address book
// tab (Recent connections, Favorites, ...) can lead with the name an admin
// gave a machine instead of its raw hostname -- see getPeerLabel in
// widgets/peer_card.dart. Filled from the address book's client list
// (widgets/olidesk_address_book.dart) and persisted in a local option, so
// names show at startup before, or without, a successful fetch. Stays
// empty in the client build, which has no address book.

const _kAbNamesKey = 'olidesk-ab-names';

final _names = <String, String>{}.obs;
bool _loaded = false;

String _normalizeId(String id) => id.replaceAll(' ', '');

/// The address-book name for [id], or null if it isn't in the address book.
String? olideskAbName(String id) {
  if (!_loaded) {
    _loaded = true;
    try {
      final raw = bind.mainGetLocalOption(key: _kAbNamesKey);
      if (raw.isNotEmpty) {
        _names.addAll(Map<String, String>.from(jsonDecode(raw) as Map));
      }
    } catch (_) {
      // A corrupt cache only costs names until the next fetch rewrites it.
    }
  }
  final name = _names[_normalizeId(id)];
  return (name == null || name.isEmpty) ? null : name;
}

/// Records names from an address-book fetch. [complete] means [names] is
/// the whole address book, so IDs missing from it are dropped; otherwise
/// (e.g. a single group's clients) they are merged in.
void setOlideskAbNames(Map<String, String> names, {required bool complete}) {
  olideskAbName(''); // load the persisted cache first, so a merge keeps it
  final next = complete ? <String, String>{} : Map.of(_names);
  names.forEach((id, name) => next[_normalizeId(id)] = name);
  _names.value = next;
  bind.mainSetLocalOption(key: _kAbNamesKey, value: jsonEncode(next));
}
