import '../widgets/resource_image.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/moment_post.dart';
import '../services/moments_service.dart';
import '../services/role_service.dart';
import '../services/settings_service.dart';
import '../services/image_service.dart';
import 'publish_moment_page.dart';

/// 朋友圈页面
/// ZeroChat 风格朋友圈 UI
class MomentsPage extends StatefulWidget {
  const MomentsPage({super.key});

  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

class _MomentsPageState extends State<MomentsPage> {
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;

  @override
  void initState() {
    super.initState();
    MomentsService.instance.addListener(_onPostsChanged);
    SettingsService.instance.addListener(_onSettingsChanged);
    MomentsService.instance.clearUnread();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    MomentsService.instance.removeListener(_onPostsChanged);
    SettingsService.instance.removeListener(_onSettingsChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onPostsChanged() {
    if (mounted) setState(() {});
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    setState(() {
      _scrollOffset = _scrollController.offset;
    });
  }

  bool get _showAppBar => _scrollOffset > 200;

  @override
  Widget build(BuildContext context) {
    final posts = MomentsService.instance.posts;
    final statusBarHeight = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(child: _buildCoverSection(statusBarHeight)),
              posts.isEmpty
                  ? SliverFillRemaining(child: _buildEmptyState())
                  : SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => _buildPostCard(posts[index]),
                        childCount: posts.length,
                      ),
                    ),
              const SliverToBoxAdapter(child: SizedBox(height: 60)),
            ],
          ),
          _buildTopBar(statusBarHeight),
        ],
      ),
    );
  }

  Widget _buildCoverSection(double statusBarHeight) {
    final nickname = SettingsService.instance.userNickname.isNotEmpty
        ? SettingsService.instance.userNickname
        : '我';

    return Stack(
      children: [
        // 封面背景
        Container(
          height: 320,
          width: double.infinity,
          decoration: SettingsService.instance.coverImageUrl.isEmpty
              ? const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF2C3E50),
                      Color(0xFF34495E),
                      Color(0xFF1A252F),
                    ],
                  ),
                )
              : null,
          child: SettingsService.instance.coverImageUrl.isNotEmpty
              ? _buildCoverImage()
              : const Center(
                  child: Icon(
                    Icons.image_outlined,
                    size: 48,
                    color: Color(0x33FFFFFF),
                  ),
                ),
        ),
        Positioned(
          right: 12,
          bottom: 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    nickname,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        Shadow(
                          offset: Offset(0, 1),
                          blurRadius: 4,
                          color: Colors.black45,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              _buildUserAvatar(),
            ],
          ),
        ),
        Positioned(
          top: statusBarHeight + 8,
          left: 8,
          child: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(
              Icons.arrow_back_ios,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
        Positioned(
          top: statusBarHeight + 8,
          right: 8,
          child: IconButton(
            onPressed: _publishMoment,
            icon: const Icon(
              Icons.camera_alt_outlined,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCoverImage() {
    final coverUrl = SettingsService.instance.coverImageUrl;
    final fallback = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C3E50), Color(0xFF34495E), Color(0xFF1A252F)],
        ),
      ),
    );

    if (ImageService.isLocalPath(coverUrl)) {
      return Image.file(
        File(coverUrl),
        fit: BoxFit.cover,
        width: double.infinity,
        height: 320,
        errorBuilder: (_, __, ___) => fallback,
      );
    } else {
      return ResourceImage(
        coverUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: 320,
        errorBuilder: (_, __, ___) => fallback,
      );
    }
  }

  Widget _buildUserAvatar() {
    final rawAvatarUrl = SettingsService.instance.userAvatarUrl;
    final nickname = SettingsService.instance.userNickname.isNotEmpty
        ? SettingsService.instance.userNickname
        : '我';

    // 如果是相对路径，加上后端URL前缀
    String avatarUrl = rawAvatarUrl;
    if (rawAvatarUrl.isNotEmpty && rawAvatarUrl.startsWith('/')) {
      avatarUrl = '${SettingsService.instance.backendUrl}$rawAvatarUrl';
    }

    if (avatarUrl.isNotEmpty) {
      return Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ResourceImage(
            avatarUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildDefaultUserAvatar(nickname),
          ),
        ),
      );
    }
    return _buildDefaultUserAvatar(nickname);
  }

  Widget _buildDefaultUserAvatar(String nickname) {
    return Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        color: const Color(0xFF07C160),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4)),
        ],
      ),
      child: Center(
        child: Text(
          nickname.isNotEmpty ? nickname[0] : '我',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(double statusBarHeight) {
    return AnimatedOpacity(
      opacity: _showAppBar ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 150),
      child: IgnorePointer(
        ignoring: !_showAppBar,
        child: Container(
          padding: EdgeInsets.only(top: statusBarHeight),
          height: statusBarHeight + 44,
          decoration: BoxDecoration(
            color: const Color(0xFFF7F7F7).withValues(alpha: 0.95),
            border: const Border(
              bottom: BorderSide(color: Color(0xFFE5E5E5), width: 0.5),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_ios, size: 20),
              ),
              const Expanded(
                child: Center(
                  child: Text(
                    '朋友圈',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                onPressed: _publishMoment,
                icon: const Icon(Icons.camera_alt_outlined, size: 22),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 56,
            color: Color(0xFFCCCCCC),
          ),
          SizedBox(height: 12),
          Text(
            '暂无动态',
            style: TextStyle(color: Color(0xFF888888), fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildPostCard(MomentPost post) {
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(post),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.authorName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF576B95),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  post.content,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF1A1A1A),
                    height: 1.45,
                  ),
                ),
                if (post.stickerPath != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.asset(
                      post.stickerPath!,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      _formatTime(post.createdAt),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFB2B2B2),
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => _showActionMenu(post),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Icon(
                          Icons.more_horiz,
                          size: 16,
                          color: Color(0xFF576B95),
                        ),
                      ),
                    ),
                  ],
                ),
                if (post.likedBy.isNotEmpty || post.comments.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildInteractionArea(post),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractionArea(MomentPost post) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F7F7),
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (post.likedBy.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.favorite, size: 14, color: Color(0xFF576B95)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    _formatLikedBy(post.likedBy),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF576B95),
                    ),
                  ),
                ),
              ],
            ),
          if (post.likedBy.isNotEmpty && post.comments.isNotEmpty)
            const Divider(height: 10, color: Color(0xFFE8E8E8)),
          ...post.comments.map(
            (c) => GestureDetector(
              onTap: () => _showCommentDialog(post, replyTo: c),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: c.authorId == 'me' ? '我' : c.authorName,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF576B95),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (c.replyToName != null) ...[
                        const TextSpan(
                          text: ' 回复 ',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                        TextSpan(
                          text: c.replyToName,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF576B95),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      TextSpan(
                        text: '：${c.content}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(MomentPost post) {
    // 从 RoleService 获取最新头像
    String? avatarUrl = post.authorAvatarUrl;
    final role = RoleService.getRoleById(post.authorId);
    if (role != null && role.avatarUrl != null && role.avatarUrl!.isNotEmpty) {
      avatarUrl = role.avatarUrl;
    }

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ResourceImage(
          avatarUrl,
          width: 42,
          height: 42,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildDefaultAvatar(post),
        ),
      );
    }
    return _buildDefaultAvatar(post);
  }

  Widget _buildDefaultAvatar(MomentPost post) {
    final color = post.isFromUser
        ? const Color(0xFF07C160)
        : Color((post.authorId.hashCode & 0xFFFFFF) | 0xFF000000);
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: Text(
          post.authorName.isNotEmpty ? post.authorName[0] : '?',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _showActionMenu(MomentPost post) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFDDDDDD),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Icon(
                  post.isLikedByMe ? Icons.favorite : Icons.favorite_border,
                  color: post.isLikedByMe
                      ? Colors.red
                      : const Color(0xFF333333),
                ),
                title: Text(post.isLikedByMe ? '取消赞' : '赞'),
                onTap: () async {
                  Navigator.pop(context);
                  try { await MomentsService.instance.toggleLike(post.id); }
                  catch (error) { if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('$error'))); }
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.chat_bubble_outline,
                  color: Color(0xFF333333),
                ),
                title: const Text('评论'),
                onTap: () {
                  Navigator.pop(context);
                  _showCommentDialog(post);
                },
              ),
              if (post.isFromUser) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('删除'),
                  onTap: () {
                    Navigator.pop(context);
                    _confirmDelete(post);
                  },
                ),
              ],
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  void _showCommentDialog(MomentPost post, {MomentComment? replyTo}) {
    final controller = TextEditingController();
    final replyName = replyTo?.authorId == 'me' ? '我' : replyTo?.authorName;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: replyTo != null ? '回复 $replyName：' : '评论...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: Color(0xFFE5E5E5)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                final content = controller.text.trim();
                if (content.isNotEmpty) {
                  try { await MomentsService.instance.addComment(
                    post.id,
                    authorId: 'me',
                    authorName: SettingsService.instance.userNickname.isNotEmpty
                        ? SettingsService.instance.userNickname
                        : '我',
                    content: content,
                    replyToId: replyTo?.authorId,
                    replyToName: replyName,
                  ); } catch (error) {
                    if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('$error')));
                    return;
                  }
                }
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('发送'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(MomentPost post) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除动态'),
        content: const Text('确定要删除这条朋友圈吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              try { await MomentsService.instance.deletePost(post.id); if (context.mounted) Navigator.pop(context); }
              catch (error) { if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('$error'))); }
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _publishMoment() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PublishMomentPage()),
    );
  }

  String _formatLikedBy(List<String> likedBy) {
    return likedBy
        .map((id) {
          if (id == 'me') return '我';
          final role = RoleService.getRoleById(id);
          return role?.name ?? id;
        })
        .join(', ');
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${time.month}月${time.day}日';
  }
}
