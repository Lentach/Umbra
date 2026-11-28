import 'package:fireplace/services/box/box_friend_gate.dart';
import 'package:fireplace/services/contacts/contact_record.dart';
import 'package:flutter_test/flutter_test.dart';

ContactOutbound _addr(String sid, String? idk, {int device = 1}) =>
    ContactOutbound(
      peerDeviceId: device,
      sid: sid,
      sealPub: 'p',
      idk: idk,
    );

void main() {
  // Owner reversal 2026-11-27: the red key-change bar never closes the gate
  // (a forged bar must not silence a chat); only a calm hold does. The gate
  // has no red clause to test: the app wiring is pinned by
  // `connection_provider_labelled_wiring_test`.

  late List<ContactOutbound> held;
  String? anchor;
  var judged = true;
  var calm = false;
  late FriendGate gate;

  setUp(() {
    held = [_addr('OLD', 'A')];
    anchor = 'A';
    judged = true;
    calm = false;
    gate = FriendGate(
      addressesOf: (_) => held,
      anchorOf: (_) => anchor,
      journalJudged: () => judged,
    )..calmHeld = (_) => calm;
  });

  test('a current address under the pinned identity is written to', () {
    final permit = gate.permitFor(1, to: held)!;
    expect(gate.refusalOf(permit, 'OLD'), isNull);
  });

  test('no permit is refused', () {
    expect(gate.refusalOf(null, 'OLD'), FriendGateRefusal.noPermit);
  });

  test('a sid the friend does not hold is refused', () {
    final permit = gate.permitFor(1)!;
    expect(gate.refusalOf(permit, 'ELSEWHERE'), FriendGateRefusal.unknownAddress);
  });

  test('the anchor moved: the old address is stale, no permit is given', () {
    anchor = 'B';
    expect(gate.permitFor(1, to: held), isNull);
  });

  test('the anchor moves after the permit: sealed under A, not written', () {
    final permit = gate.permitFor(1, to: held)!;
    anchor = 'B';
    held = [_addr('NEW', 'B')];
    expect(gate.refusalOf(permit, 'NEW'), FriendGateRefusal.permitIdentity);
  });

  test('the address changes under a permit: the stale one is refused', () {
    final permit = gate.permitFor(1, to: held)!;
    held = [_addr('OLD', 'A'), _addr('OLD', 'A')];
    anchor = 'A';
    held = [_addr('OLD', 'Z')];
    expect(gate.refusalOf(permit, 'OLD'), FriendGateRefusal.staleAddress);
  });

  test('a calm hold closes the gate, before and after the permit', () {
    calm = true;
    expect(gate.permitFor(1), isNull);
    calm = false;
    final permit = gate.permitFor(1)!;
    calm = true;
    expect(gate.refusalOf(permit, 'OLD'), FriendGateRefusal.calmHeld);
  });

  test('an unjudged journal closes the gate; a goodbye is exempt', () {
    judged = false;
    expect(gate.permitFor(1), isNull);
    final goodbye = gate.permitFor(1, goodbye: true)!;
    expect(gate.refusalOf(goodbye, 'OLD'), isNull);
    final other = FriendPermit.forTest(1, identity: 'A');
    expect(gate.refusalOf(other, 'OLD'), FriendGateRefusal.journalUnjudged);
  });

  test('no anchor pinned: the permit takes the pin its own encrypt makes', () {
    anchor = null;
    held = [_addr('OLD', null)];
    final permit = gate.permitFor(1, to: held)!;
    expect(permit.firstPin, isTrue);
    anchor = 'A';
    expect(permit.admitsSession('A'), isTrue);
    expect(gate.refusalOf(permit, 'OLD'), isNull);
  });

  test('no anchor pinned: a restored tag that differs from the pin waits', () {
    anchor = null;
    held = [_addr('OLD', 'X')];
    final permit = gate.permitFor(1, to: held)!;
    anchor = 'A';
    expect(permit.admitsSession('A'), isTrue);
    expect(gate.refusalOf(permit, 'OLD'), FriendGateRefusal.staleAddress);
  });

  test('a session of another identity than the permit is not admitted', () {
    final permit = gate.permitFor(1, to: held)!;
    expect(permit.admitsSession('B'), isFalse);
    expect(permit.admitsSession('A'), isTrue);
  });
}
