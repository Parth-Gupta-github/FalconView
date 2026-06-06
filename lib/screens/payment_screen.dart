import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_tier.dart';
import '../services/subscription_service.dart';
import '../theme/tactical_theme.dart';

/// Dev-mode checkout. Looks like a real Razorpay-style page but processing
/// is faked: any tap on "Pay" waits ~2s, flips the tier via
/// [subscriptionService], and pops with `true`. Swap [_simulatePayment] for
/// a real PSP SDK call later — the rest of the screen stays.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.tier});

  final AppTier tier;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen>
    with SingleTickerProviderStateMixin {
  static const int _priceInr = 499;
  static const Duration _fakeProcessing = Duration(seconds: 2);

  late final TabController _tabs;
  final TextEditingController _upi = TextEditingController();
  final TextEditingController _cardNumber = TextEditingController();
  final TextEditingController _cardExpiry = TextEditingController();
  final TextEditingController _cardCvv = TextEditingController();

  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _upi.dispose();
    _cardNumber.dispose();
    _cardExpiry.dispose();
    _cardCvv.dispose();
    super.dispose();
  }

  Future<void> _onPay() async {
    if (_processing) return;
    setState(() => _processing = true);
    final bool ok = await _simulatePayment();
    if (!mounted) return;
    if (!ok) {
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment failed. Please try again.')),
      );
      return;
    }
    await subscriptionService.setTier(widget.tier);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<bool> _simulatePayment() async {
    await Future<void>.delayed(_fakeProcessing);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_processing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Complete purchase'),
          leading: const BackButton(),
        ),
        body: _widthCap(child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              children: [
                const _DevModeBanner(),
                const SizedBox(height: 12),
                _OrderSummary(tier: widget.tier, priceInr: _priceInr),
                const SizedBox(height: 16),
                _MethodTabs(controller: _tabs),
                SizedBox(
                  height: 260,
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _UpiTab(controller: _upi),
                      _CardTab(
                        number: _cardNumber,
                        expiry: _cardExpiry,
                        cvv: _cardCvv,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: TacticalPalette.scaffold,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _processing ? null : _onPay,
                        icon: _processing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.lock),
                        label: Text(
                          _processing
                              ? 'Processing payment…'
                              : 'Pay ₹$_priceInr',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        )),
      ),
    );
  }

  /// Cap the checkout body width and center it on any wide surface — web,
  /// Windows/macOS/Linux desktop, large tablets, resized windows — so the
  /// checkout doesn't stretch edge-to-edge. Purely width-driven: on narrow
  /// phones the available width is already below the cap, so it's a no-op.
  static const double _maxContentWidth = 560;

  Widget _widthCap({required Widget child}) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth <= _maxContentWidth) return child;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: child,
          ),
        );
      },
    );
  }
}

class _DevModeBanner extends StatelessWidget {
  const _DevModeBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        border: Border.all(color: const Color(0xFFFB923C)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.science_outlined, color: Color(0xFFC2410C)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Dev mode — payment is simulated. No real charge is made.',
              style: TextStyle(
                color: Color(0xFFC2410C),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderSummary extends StatelessWidget {
  const _OrderSummary({required this.tier, required this.priceInr});

  final AppTier tier;
  final int priceInr;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TacticalPalette.panel,
        border: Border.all(color: TacticalPalette.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORDER SUMMARY',
            style: TextStyle(
              color: TacticalPalette.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.workspace_premium,
                  color: TacticalPalette.accent, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FalconView ${tier.label}',
                      style: const TextStyle(
                        color: TacticalPalette.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '1-year subscription · cancel anytime',
                      style: TextStyle(
                        color: TacticalPalette.textDim,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '₹$priceInr',
                style: const TextStyle(
                  color: TacticalPalette.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Total payable',
                  style: TextStyle(
                    color: TacticalPalette.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '₹$priceInr',
                style: const TextStyle(
                  color: TacticalPalette.accent,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MethodTabs extends StatelessWidget {
  const _MethodTabs({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TacticalPalette.panel,
        border: Border.all(color: TacticalPalette.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: TabBar(
        controller: controller,
        labelColor: TacticalPalette.accent,
        unselectedLabelColor: TacticalPalette.textDim,
        indicatorColor: TacticalPalette.accent,
        indicatorSize: TabBarIndicatorSize.tab,
        tabs: const <Widget>[
          Tab(icon: Icon(Icons.account_balance_wallet_outlined), text: 'UPI'),
          Tab(icon: Icon(Icons.credit_card), text: 'Card'),
        ],
      ),
    );
  }
}

class _UpiTab extends StatelessWidget {
  const _UpiTab({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Pay with any UPI app',
            style: TextStyle(
              color: TacticalPalette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              hintText: 'yourname@upi',
              prefixIcon: const Icon(Icons.alternate_email),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Or pick an app',
            style: TextStyle(
              color: TacticalPalette.textDim,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          const Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _AppBadge(label: 'GPay'),
              _AppBadge(label: 'PhonePe'),
              _AppBadge(label: 'Paytm'),
              _AppBadge(label: 'BHIM'),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppBadge extends StatelessWidget {
  const _AppBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: TacticalPalette.accentSoft,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: TacticalPalette.accent,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _CardTab extends StatelessWidget {
  const _CardTab({
    required this.number,
    required this.expiry,
    required this.cvv,
  });

  final TextEditingController number;
  final TextEditingController expiry;
  final TextEditingController cvv;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: number,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(19),
            ],
            decoration: InputDecoration(
              labelText: 'Card number',
              hintText: '1234 5678 9012 3456',
              prefixIcon: const Icon(Icons.credit_card),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: expiry,
                  keyboardType: TextInputType.datetime,
                  inputFormatters: <TextInputFormatter>[
                    LengthLimitingTextInputFormatter(5),
                  ],
                  decoration: InputDecoration(
                    labelText: 'MM/YY',
                    hintText: '12/29',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: cvv,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  decoration: InputDecoration(
                    labelText: 'CVV',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Icon(Icons.shield_outlined,
                  size: 16, color: TacticalPalette.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Card details are not stored. PCI-DSS compliant.',
                  style: TextStyle(
                    color: TacticalPalette.textDim,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
