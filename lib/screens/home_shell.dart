import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'library_screen.dart';
import 'mine_screen.dart';

/// 底部导航壳：书架 / 我的 两个 tab。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [LibraryScreen(), MineScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppColors.bgElevated,
        indicatorColor: AppColors.accent.withValues(alpha: 0.18),
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
