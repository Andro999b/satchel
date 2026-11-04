import 'package:flutter/material.dart';

/// Bottom padding for a list under a floating action button, so the button
/// never covers the actions of the last row.
const fabListPadding = EdgeInsets.only(bottom: 56 + 2 * 16);

/// Like [fabListPadding], for a small button stacked above a regular one.
const twoFabListPadding = EdgeInsets.only(bottom: 56 + 40 + 3 * 16);
