import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'firebase_boot.dart';

/// Optional Firebase Authentication and Cloud Firestore.
///
/// CamAnime keeps its own email/password + session-cookie auth on the backend.
/// These layers are *prepared* but switched off: nothing in the app calls them
/// unless a flag below is turned on, so accounts, history and library behaviour
/// are unchanged.
///
/// Enable them only after deciding what should live in Firebase, and remember
/// that Firestore security rules — not this file — are the real access control.
const bool kEnableFirebaseAuth = false;
const bool kEnableFirestore = false;

class FirebaseOptional {
  FirebaseOptional._();

  static bool get authAvailable => firebaseReady && kEnableFirebaseAuth;
  static bool get firestoreAvailable => firebaseReady && kEnableFirestore;

  static bool get firebaseReady => FirebaseBoot.ready;

  /// Anonymous sign-in, used only when [kEnableFirebaseAuth] is on. Returns the
  /// uid, or null when disabled/unavailable. Never throws.
  static Future<String?> ensureSignedIn() async {
    if (!authAvailable) return null;
    try {
      final auth = FirebaseAuth.instance;
      final current = auth.currentUser;
      if (current != null) return current.uid;
      final cred = await auth.signInAnonymously();
      return cred.user?.uid;
    } catch (err) {
      debugPrint('Firebase anonymous sign-in failed: $err');
      return null;
    }
  }

  /// A user-scoped collection reference, or null when Firestore is off.
  static CollectionReference<Map<String, dynamic>>? collection(String path) {
    if (!firestoreAvailable || path.isEmpty) return null;
    try {
      return FirebaseFirestore.instance.collection(path);
    } catch (err) {
      debugPrint('Firestore unavailable: $err');
      return null;
    }
  }
}
