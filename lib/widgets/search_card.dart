import 'package:flutter/material.dart';

import '../theme/tactical_theme.dart';

class SearchCard extends StatelessWidget {
  final VoidCallback onTap;
  const SearchCard({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      color: TacticalPalette.panel,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: const [
              Icon(Icons.search, color: TacticalPalette.accent),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Search any city or district…',
                  style: TextStyle(
                    color: TacticalPalette.textDim,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
