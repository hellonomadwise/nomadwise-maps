import 'package:flutter/material.dart';

import 'claim_screen.dart';

/// nomadmaps.io/pricing (and ?pricing). Jonathan, 30 Oct 2026: "the
/// only thing that it shows to begin with, is to find your space. so
/// they maintain curiosity". It is the claim page, opened from the
/// pricing link: find your space first, then Free and Premium with the
/// price for that space's country (step two), then your details.
/// No country dropdown any more: the space says where it is.
class PricingScreen extends StatelessWidget {
  const PricingScreen({super.key});

  @override
  Widget build(BuildContext context) => const ClaimScreen(from: 'pricing');
}
