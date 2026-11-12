import 'package:flutter/material.dart';

/// White grouped settings, with separators and modest spacing like the existing settings page.
class WechatFormList extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  const WechatFormList({super.key, required this.children, this.padding});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [for (final child in children)
        if (child is Divider) const SizedBox(height: 12)
        else Container(
          decoration: const BoxDecoration(color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE5E5E5), width: .5))),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: child)],
    );
  }
}
