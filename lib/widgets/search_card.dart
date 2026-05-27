import 'package:flutter/material.dart';

class SearchCard extends StatelessWidget {
  final VoidCallback onTap;
  const SearchCard({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      color: Colors.white,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: const [
              Icon(Icons.search, color: Colors.black54),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Search any city or district…',
                  style: TextStyle(color: Colors.black54, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
