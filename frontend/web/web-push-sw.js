/**
 * Push SW for Fireplace — scope `/web-push-scope/`.
 * Companion: frontend/lib/services/web_push_bridge_web.dart
 *            frontend/lib/services/push_sw_channel_web.dart
 *            frontend/lib/utils/pending_deep_link_web.dart
 *
 * APP_BADGE_MAX must match kAppBadgeMaxDisplayCount in frontend/lib/utils/app_badge_math.dart
 * DEEPLINK_* constants must match frontend/lib/utils/pending_deep_link_web.dart
 *
 * This SW is the single writer for the app icon badge and the notification tray.
 * The page never touches them directly — it posts messages here (see the
 * 'message' handler), because iOS WebKit requires these to run in SW context
 * to survive WebView suspension and to avoid racing the push handler.
 */
const APP_BADGE_MAX = 19;

const DEEPLINK_DB = 'fireplace-push';
const DEEPLINK_STORE = 'kv';
const DEEPLINK_KEY = 'pending-deep-link';

// ---------- Badge helpers ----------

function setBadgeFromSW(n) {
  try {
    const nav = self.navigator;
    if (!nav || typeof nav.setAppBadge !== 'function') return Promise.resolve();
    if (n <= 0) {
      // iOS Safari requires integer overload (not no-arg) for clearAppBadge
      const result = typeof nav.clearAppBadge === 'function'
        ? nav.clearAppBadge()
        : nav.setAppBadge(0);
      return result && typeof result.then === 'function'
        ? result.catch(function () {})
        : Promise.resolve();
    }
    const clamped = n > APP_BADGE_MAX ? APP_BADGE_MAX : n;
    const result = nav.setAppBadge(clamped);
    return result && typeof result.then === 'function'
      ? result.catch(function () {})
      : Promise.resolve();
  } catch (_) {
    return Promise.resolve();
  }
}

// ---------- Notification helpers ----------

// Close every shown notification carrying exactly this tag. iOS WebKit never
// replaces same-tag notifications (WebKit bug 258922), so the push handler
// emulates tag replacement with close-then-show; on engines with working tag
// replacement this is a harmless no-op pass.
// Queries BOTH the spec'd filtered form and an unfiltered scan and closes the
// union — belt-and-suspenders against engines where one form is unreliable.
// Closing the same notification twice is a harmless no-op. Hard limit (iOS):
// neither form can return notifications shown by a PREVIOUS SW instance, so
// cards from older bursts stay until the user swipes them.
function closeNotificationsForTag(tag) {
  function getSafe(filter) {
    try {
      var p = filter
        ? self.registration.getNotifications(filter)
        : self.registration.getNotifications();
      return p.catch(function () { return []; });
    } catch (_) {
      return Promise.resolve([]);
    }
  }
  return Promise.all([getSafe({ tag: tag }), getSafe(null)])
    .then(function (results) {
      for (var r = 0; r < results.length; r++) {
        var list = results[r] || [];
        for (var i = 0; i < list.length; i++) {
          if (list[i].tag === tag) {
            try { list[i].close(); } catch (_) {}
          }
        }
      }
    })
    .catch(function () {});
}

// Close any shown notification whose conversationId is NOT in unreadConvIds.
function sweepStaleNotifications(unreadConvIds) {
  var idSet = new Set(unreadConvIds.map(Number));
  return self.registration.getNotifications().then(function (notifications) {
    for (var i = 0; i < notifications.length; i++) {
      var n = notifications[i];
      var tag = n.tag || '';
      if (tag.indexOf('conversation-') !== 0) continue;
      var convId = Number(tag.slice('conversation-'.length));
      if (!isNaN(convId) && !idSet.has(convId)) {
        try { n.close(); } catch (_) {}
      }
    }
  }).catch(function () {});
}

// ---------- Pending deep-link (IndexedDB) ----------
// On a killed iOS PWA, notificationclick's clients.openWindow(url) opens the
// app at its manifest start_url and DROPS the URL (incl. ?notify_conv=), so
// the conversation id is persisted here and the page drains it on launch /
// resume. IndexedDB is the only storage shared between this SW and the page.

function openDeepLinkDb() {
  return new Promise(function (resolve, reject) {
    var req = indexedDB.open(DEEPLINK_DB, 1);
    req.onupgradeneeded = function () {
      try { req.result.createObjectStore(DEEPLINK_STORE); } catch (_) {}
    };
    req.onsuccess = function () { resolve(req.result); };
    req.onerror = function () { reject(req.error); };
  });
}

function storePendingDeepLink(conversationId) {
  return openDeepLinkDb().then(function (db) {
    return new Promise(function (resolve) {
      try {
        var tx = db.transaction(DEEPLINK_STORE, 'readwrite');
        tx.objectStore(DEEPLINK_STORE).put(
          { conversationId: conversationId, at: Date.now() },
          DEEPLINK_KEY
        );
        tx.oncomplete = function () { db.close(); resolve(); };
        tx.onabort = function () { db.close(); resolve(); };
        tx.onerror = function () { db.close(); resolve(); };
      } catch (_) { db.close(); resolve(); }
    });
  }).catch(function () {});
}

// ---------- Push handler ----------

// Which conversation each focused client is viewing (set via the page's
// 'active-conversation' message, keyed by client id — multi-tab safe). Used to
// suppress a push banner for a chat the user is already looking at. In-memory
// only: after an SW restart it is empty until the page re-posts on next focus.
var focusedConvByClient = {};

// Resolves true when a focused, visible client is viewing [convId]; also prunes
// entries for clients that have gone away. Fails open (false) on any error so a
// client-query failure never blocks delivery.
function shouldSuppressForFocusedConversation(convId) {
  if (convId == null) return Promise.resolve(false);
  return clients
    .matchAll({ type: 'window', includeUncontrolled: true })
    .then(function (all) {
      var present = {};
      for (var i = 0; i < all.length; i++) present[all[i].id] = true;
      Object.keys(focusedConvByClient).forEach(function (id) {
        if (!present[id]) delete focusedConvByClient[id];
      });
      for (var j = 0; j < all.length; j++) {
        var c = all[j];
        if (
          c.focused &&
          c.visibilityState === 'visible' &&
          focusedConvByClient[c.id] === convId
        ) {
          return true;
        }
      }
      return false;
    })
    .catch(function () {
      return false;
    });
}

// True when this subscription is on Apple's push service, where a push that
// posts no notification counts toward Safari's revoke-after-3-silent budget.
// Fails toward true: posting a card that closes at once is harmless.
function isApplePushEndpoint() {
  return self.registration.pushManager
    .getSubscription()
    .then(function (sub) {
      var endpoint = sub && sub.endpoint ? sub.endpoint : '';
      return endpoint.indexOf('https://web.push.apple.com/') === 0;
    })
    .catch(function () { return true; });
}

// Posts a silent card under [tag] and closes it at once: the push kept its
// `userVisibleOnly` promise, and nothing stays in the tray.
function postAndClose(title, body, tag, data) {
  return self.registration
    .showNotification(title, {
      body: body,
      icon: '/icons/notification-icon-512.png',
      badge: '/icons/notification-badge-96.png',
      tag: tag,
      data: data,
      silent: true,
    })
    .then(function () { return closeNotificationsForTag(tag); });
}

// Box push registration (metadata-privacy E9): a `notifier_challenge` code
// proves this subscription reaches the page that holds the queue key. It is
// handed to every open page — the one registering answers it — and is never
// a "New message" card. But a push that posts NO notification is a broken
// promise (`userVisibleOnly`): Safari REVOKES the subscription after three
// (WebKit, WWDC22), and Chrome posts its own generic card when no page of
// ours is visible. So one is posted and closed at once, unless a visible
// page took the code on a non-Apple push service.
function handleNotifierChallenge(code) {
  function flash() {
    return postAndClose('Umbra', 'Setting up notifications', 'box-notifier');
  }
  return clients
    .matchAll({ type: 'window', includeUncontrolled: true })
    .then(function (all) {
      var visible = false;
      for (var i = 0; i < all.length; i++) {
        if (typeof code === 'string') {
          all[i].postMessage({ type: 'box-notifier-challenge', code: code });
        }
        if (all[i].visibilityState === 'visible') visible = true;
      }
      return isApplePushEndpoint().then(function (apple) {
        return visible && !apple ? undefined : flash();
      });
    })
    .catch(flash);
}

self.addEventListener('push', function (event) {
  var payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch (_) {}

  if (payload.type === 'notifier_challenge') {
    event.waitUntil(handleNotifierChallenge(payload.code));
    return;
  }

  // Phase 0a takeover alarm: content-free security notice — the account's
  // key bundle was replaced by another sign-in. No conversation, no unread
  // math, no sweep/badge writes; the app shows the durable banner itself on
  // next open. Wording is the consented-recovery framing: this fires on every
  // legitimate reinstall/new-browser sign-in too, so it must not say "hacked".
  if (payload.type === 'identity_changed') {
    event.waitUntil(
      closeNotificationsForTag('identity-changed').then(function () {
        return self.registration.showNotification('Fireplace', {
          body: 'New encryption keys on your account — usually a new device or browser sign-in. Open the app to review.',
          icon: '/icons/notification-icon-512.png',
          badge: '/icons/notification-badge-96.png',
          tag: 'identity-changed',
          data: payload,
          renotify: true,
        });
      })
    );
    return;
  }

  // Phase 0b reset ceremony: content-free notice that a countdown toward new
  // account keys has started. Push is the ONLY channel that reaches a closed
  // app, and the delay exists precisely so this can arrive in time — so it is
  // required interaction and does not auto-dismiss.
  if (payload.type === 'identity_reset_pending') {
    event.waitUntil(
      closeNotificationsForTag('identity-reset').then(function () {
        return self.registration.showNotification('Fireplace', {
          body: 'Someone asked to reset your account encryption keys. If this was not you, open the app and cancel it.',
          icon: '/icons/notification-icon-512.png',
          badge: '/icons/notification-badge-96.png',
          tag: 'identity-reset',
          data: payload,
          renotify: true,
          requireInteraction: true,
        });
      })
    );
    return;
  }

  // The ceremony was cancelled: replace the standing warning rather than
  // leaving a stale "act now" notification on the lock screen.
  if (payload.type === 'identity_reset_cancelled') {
    event.waitUntil(
      closeNotificationsForTag('identity-reset').then(function () {
        return self.registration.showNotification('Fireplace', {
          body: 'The encryption key reset was cancelled.',
          icon: '/icons/notification-icon-512.png',
          badge: '/icons/notification-badge-96.png',
          tag: 'identity-reset',
          data: payload,
        });
      })
    );
    return;
  }

  // The account's recovery phrase was set or replaced (spec §12 amendment
  // (xlii)). A recovery phrase is what shortens the reset delay, so arming one
  // is a security-relevant act in its own right and must not happen silently:
  // a thief holding a stolen session would otherwise pre-arm a phrase with the
  // owner none the wiser. Its OWN tag, never the 'identity-reset' one — this
  // must not replace, or be replaced by, a live countdown warning.
  if (payload.type === 'recovery_key_enrolled') {
    event.waitUntil(
      self.registration.showNotification('Fireplace', {
        body: 'A recovery phrase was set for your account. If this was not you, change your password now.',
        icon: '/icons/notification-icon-512.png',
        badge: '/icons/notification-badge-96.png',
        tag: 'recovery-key-enrolled',
        data: payload,
        requireInteraction: true,
      })
    );
    return;
  }

  var convId = payload.conversationId != null ? Number(payload.conversationId) : null;
  // Per-conversation unread — card text only.
  var unreadCount = typeof payload.unreadCount === 'number'
    ? payload.unreadCount
    : (typeof payload.messageCount === 'number' ? payload.messageCount : 1);
  // Badge MUST come from the live cumulative total. When the backend failed to
  // compute it at flush time the field is absent — then we leave the badge
  // untouched rather than writing a per-burst guess (the old fallback caused
  // visible resets to 1).
  var hasUnreadTotal = typeof payload.unreadTotal === 'number';
  // null = field absent (backend error at flush time) — skip sweep rather than
  // wrongly closing other conversations' notifications.
  var unreadConvIds = Array.isArray(payload.unreadConversationIds)
    ? payload.unreadConversationIds
    : null;

  // WhatsApp/Signal model: title = sender display name (metadata-only,
  // approved), body = per-conversation unread count → "Bob: 15 new messages".
  var senderName = typeof payload.senderName === 'string' && payload.senderName
    ? payload.senderName
    : null;
  var title = senderName || 'Umbra';
  var body = unreadCount > 1
    ? unreadCount + ' new messages'
    : 'New message';

  var tag = convId != null ? 'conversation-' + convId : 'new-message';
  var notificationOptions = {
    body: body,
    // Large icon (notification body): the ember hex Umbra mark.
    icon: '/icons/notification-icon-512.png',
    // Small/status-bar icon: MUST be monochrome white-on-transparent — Android
    // renders only its alpha channel. A full-colour image here is the classic
    // "white square" bug.
    badge: '/icons/notification-badge-96.png',
    tag: tag,
    data: payload,
    // Re-alert on tag replacement (Chrome/Android); ignored by Safari, where
    // close-then-show below produces a fresh alerting notification anyway.
    renotify: true,
  };

  event.waitUntil(
    shouldSuppressForFocusedConversation(convId).then(function (suppress) {
      var chain = closeNotificationsForTag(tag);
      // Suppress ONLY the banner when the user is already viewing this chat;
      // the sweep + badge writes below must still run so other conversations'
      // tray cards and the app badge stay correct. On an Apple endpoint a
      // suppressed push still posts a silent card and closes it at once
      // (decision 39): Safari revokes the subscription after 3 silent pushes.
      if (!suppress) {
        chain = chain.then(function () {
          return self.registration.showNotification(title, notificationOptions);
        });
      } else {
        // A failed flash must not skip the sweep and badge writes below.
        chain = chain
          .then(isApplePushEndpoint)
          .then(function (apple) {
            return apple ? postAndClose(title, body, tag, payload) : undefined;
          })
          .catch(function () {});
      }
      return chain
        .then(function () {
          return unreadConvIds != null
            ? sweepStaleNotifications(unreadConvIds)
            : Promise.resolve();
        })
        .then(function () {
          return hasUnreadTotal
            ? setBadgeFromSW(payload.unreadTotal)
            : Promise.resolve();
        });
    })
  );
});

// ---------- Notification click — deep link ----------

self.addEventListener('notificationclick', function (event) {
  var data = (event.notification.data) || {};
  var convId = data.conversationId != null ? Number(data.conversationId) : null;
  // iOS has been observed dropping notification.data — recover the id from the
  // tag, which survives reliably.
  if (convId == null || isNaN(convId)) {
    var tag = event.notification.tag || '';
    if (tag.indexOf('conversation-') === 0) {
      var parsed = Number(tag.slice('conversation-'.length));
      if (!isNaN(parsed)) convId = parsed;
    }
  }
  event.notification.close();

  event.waitUntil(
    (convId != null
      ? closeNotificationsForTag('conversation-' + convId) // clear the whole group
          .then(function () { return storePendingDeepLink(convId); })
      : Promise.resolve())
      .then(function () {
        return clients.matchAll({ type: 'window', includeUncontrolled: true });
      })
      .then(function (all) {
        var best = null;
        for (var i = 0; i < all.length; i++) {
          if (all[i].focused) { best = all[i]; break; }
        }
        if (!best) {
          for (var i = 0; i < all.length; i++) {
            if (all[i].visibilityState === 'visible') { best = all[i]; break; }
          }
        }
        if (!best && all.length > 0) { best = all[0]; }

        var url = convId != null ? '/?notify_conv=' + convId : '/';

        if (best) {
          // The pending deep-link stays stored as a fallback: if this client is
          // a suspended/stale iOS WebView the message is lost, and the page
          // drains IndexedDB on resume instead. The page deletes the record
          // when either path handles it.
          best.postMessage({ type: 'push-notification-click', conversationId: convId });
          // Android field bug: focus() on a frozen/discarded WebAPK client can
          // reject, and the previously swallowed rejection made notification
          // taps do visibly nothing until the user swipe-closed the app
          // (users 48/90, Aug 2026). Fall back to opening a fresh window; the
          // inner catch keeps a blocked popup from rejecting waitUntil.
          return best.focus().catch(function () {
            return clients.openWindow(url).catch(function () {});
          });
        }
        // Cold start / killed PWA — URL param works on Android/desktop; iOS
        // ignores it (start_url) and relies on the IndexedDB record above.
        return clients.openWindow(url);
      })
  );
});

// ---------- Message handler — tray + badge ops requested by the app ----------

self.addEventListener('message', function (event) {
  var data = event.data;
  if (!data) return;
  var work = null;

  if (data.type === 'clear-badge') {
    work = setBadgeFromSW(0);
  } else if (data.type === 'set-badge') {
    work = setBadgeFromSW(typeof data.count === 'number' ? data.count : 0);
  } else if (data.type === 'close-conv') {
    var convId = Number(data.conversationId);
    work = isNaN(convId)
      ? Promise.resolve()
      : closeNotificationsForTag('conversation-' + convId);
    if (typeof data.unreadTotal === 'number') {
      var totalAfterClose = data.unreadTotal;
      work = work.then(function () { return setBadgeFromSW(totalAfterClose); });
    }
  } else if (data.type === 'sweep') {
    var ids = Array.isArray(data.unreadConversationIds)
      ? data.unreadConversationIds
      : [];
    work = sweepStaleNotifications(ids);
    if (typeof data.unreadTotal === 'number') {
      var totalAfterSweep = data.unreadTotal;
      work = work.then(function () { return setBadgeFromSW(totalAfterSweep); });
    }
  } else if (data.type === 'active-conversation') {
    // Record which conversation this client is viewing (or clear it). Keyed by
    // client id so multiple tabs don't clobber each other; pruned on push.
    if (event.source && event.source.id) {
      var acId = data.conversationId != null ? Number(data.conversationId) : null;
      if (acId == null || isNaN(acId)) {
        delete focusedConvByClient[event.source.id];
      } else {
        focusedConvByClient[event.source.id] = acId;
      }
    }
  }

  if (work && event.waitUntil) {
    try { event.waitUntil(work); } catch (_) {}
  }
});

// ---------- Subscription change ----------

self.addEventListener('pushsubscriptionchange', function (event) {
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
      for (var i = 0; i < clientList.length; i++) {
        clientList[i].postMessage({ type: 'push-subscription-change' });
      }
    })
  );
});
