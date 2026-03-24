import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/moment_post.dart';
import '../models/role.dart';
import '../services/moments_service.dart';
import '../services/role_service.dart';
import '../services/api_service.dart';
import '../services/task_service.dart';

/// AI 朋友圈调度器
/// 负责 AI 角色自动发布朋友圈和互动行为
class MomentsScheduler {
  static final MomentsScheduler _instance = MomentsScheduler._internal();
  factory MomentsScheduler() => _instance;
  MomentsScheduler._internal();

  static MomentsScheduler get instance => _instance;

  final Random _random = Random();
  Timer? _schedulerTimer;

  /// 上次发布时间（每个角色）
  final Map<String, DateTime> _lastPostTime = {};

  /// 上次互动时间（每个角色）
  final Map<String, DateTime> _lastInteractTime = {};

  /// 初始化调度器
  Future<void> init() async {
    _startScheduler();
    debugPrint('MomentsScheduler: Initialized');
  }

  /// 启动定时调度
  void _startScheduler() {
    _schedulerTimer?.cancel();
    // 每 30-60 分钟检查一次
    _schedulerTimer = Timer.periodic(
      Duration(minutes: 30 + _random.nextInt(30)),
      (_) => _onSchedulerTick(),
    );

    // 启动后延迟 5-15 分钟首次检查
    Future.delayed(
      Duration(minutes: 5 + _random.nextInt(10)),
      () => _onSchedulerTick(),
    );
  }

  void _onSchedulerTick() async {
    if (TaskService.isQuietTime()) {
      debugPrint('MomentsScheduler: Skipping due to quiet time');
      return;
    }

    // 随机选择是否触发 AI 发布
    if (_random.nextDouble() < 0.15) {
      // 15% 概率
      await _triggerAIPost();
    }

    // 随机选择是否触发 AI 互动
    if (_random.nextDouble() < 0.25) {
      // 25% 概率
      await _triggerAIInteraction();
    }

    // 随机选择是否回复用户评论
    if (_random.nextDouble() < 0.30) {
      // 30% 概率
      await _triggerAIReplyToUserComment();
    }
  }

  /// 触发 AI 发布朋友圈
  Future<void> _triggerAIPost() async {
    final roles = RoleService.getAllRoles();
    if (roles.isEmpty) return;

    // 随机选择一个角色
    final role = roles[_random.nextInt(roles.length)];

    // 检查冷却时间（至少 8 小时）
    final lastPost = _lastPostTime[role.id];
    if (lastPost != null && DateTime.now().difference(lastPost).inHours < 8) {
      return;
    }

    await generateAndPostMoment(role);
  }

  /// 生成并发布 AI 朋友圈
  Future<MomentPost?> generateAndPostMoment(Role role) async {
    debugPrint('MomentsScheduler: Generating moment for ${role.name}');

    final prompt = _buildPostPrompt(role);

    // 优先通过后端生成（走后端记忆、参数）
    var response = await ApiService.callBackendAI(
      roleId: role.id,
      eventType: 'moment',
      content: prompt,
    );

    // 后端不可用时回退到前端直连
    if (!response.success && response.error?.contains('不可用') == true) {
      debugPrint('MomentsScheduler: Backend unavailable, fallback to direct API');
      response = await ApiService.sendChatMessageWithRole(
        message: prompt,
        role: role,
      );
    }

    if (!response.success || response.content == null) {
      debugPrint('MomentsScheduler: Failed to generate moment content');
      return null;
    }

    // 清理内容
    String content = response.content!.trim();
    // 移除可能的引号包裹
    if (content.startsWith('"') && content.endsWith('"')) {
      content = content.substring(1, content.length - 1);
    }
    if (content.startsWith('「') && content.endsWith('」')) {
      content = content.substring(1, content.length - 1);
    }
    // 移除 [happy] 等情绪标签
    content = content.replaceAll(RegExp(r'\[\w+\]'), '').trim();
    // 移除 $ 分隔符（分段标记）
    content = content.replaceAll(r'$', '').trim();
    // 移除多余空行
    content = content.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

    if (content.isEmpty) {
      debugPrint('MomentsScheduler: Content empty after cleaning');
      return null;
    }

    final post = await MomentsService.instance.publishAIPost(
      roleId: role.id,
      roleName: role.name,
      roleAvatarUrl: role.avatarUrl,
      content: content,
    );

    _lastPostTime[role.id] = DateTime.now();
    debugPrint('MomentsScheduler: ${role.name} posted: $content');

    return post;
  }

  /// 构建发布朋友圈的 Prompt
  String _buildPostPrompt(Role role) {
    return '''你现在要发一条朋友圈，不是聊天，不是回复任何人。

要求：
- 简短自然，像随手发的
- 可以是心情、状态、想法、碎碎念
- 带点情绪，可以略带感慨
- 不要像公告或总结
- 不要提及任何人或聊天内容
- 不要使用"我刚刚"、"今天聊到"这类表达
- 直接输出朋友圈内容，不要任何解释

示例风格（仅参考，不要复制）：
- 今天有点累，但还好。
- 突然很想喝点甜的。
- 最近好像越来越喜欢安静的时候了。

现在，基于你的性格，发一条朋友圈：''';
  }

  /// 触发 AI 互动
  Future<void> _triggerAIInteraction() async {
    final posts = MomentsService.instance.posts;
    if (posts.isEmpty) return;

    final roles = RoleService.getAllRoles();
    if (roles.isEmpty) return;

    // 随机选择一个角色
    final role = roles[_random.nextInt(roles.length)];

    // 检查冷却时间（至少 2 小时）
    final lastInteract = _lastInteractTime[role.id];
    if (lastInteract != null &&
        DateTime.now().difference(lastInteract).inHours < 2) {
      return;
    }

    // 选择一个可以互动的帖子（不是自己发的，最近 24 小时内）
    final eligiblePosts = posts.where((p) {
      if (p.authorId == role.id) return false; // 不能互动自己的
      if (DateTime.now().difference(p.createdAt).inHours > 24) return false;
      // 检查 AI-AI 互动轮数限制（最多 2 轮）
      final aiComments = p.comments
          .where((c) => c.authorId != 'me' && c.authorId != p.authorId)
          .length;
      if (aiComments >= 2) return false;
      return true;
    }).toList();

    if (eligiblePosts.isEmpty) return;

    final targetPost = eligiblePosts[_random.nextInt(eligiblePosts.length)];

    // 决定互动类型
    final interactionChance = _random.nextDouble();
    if (interactionChance < 0.6) {
      // 60% 点赞
      await _performLike(role, targetPost);
    } else if (interactionChance < 0.85) {
      // 25% 评论
      await _performComment(role, targetPost);
    }
    // 15% 不互动

    _lastInteractTime[role.id] = DateTime.now();
  }

  /// 执行点赞
  Future<void> _performLike(Role role, MomentPost post) async {
    if (post.likedBy.contains(role.id)) return;

    await MomentsService.instance.aiLike(post.id, role.id);
    debugPrint(
      'MomentsScheduler: ${role.name} liked ${post.authorName}\'s post',
    );
  }

  /// 执行评论
  Future<void> _performComment(Role role, MomentPost post) async {
    final prompt = _buildCommentPrompt(role, post);

    // 优先通过后端生成
    var response = await ApiService.callBackendAI(
      roleId: role.id,
      eventType: 'comment',
      content: prompt,
      context: {
        'post_content': post.content,
        'post_author': post.authorName,
      },
    );

    // 后端不可用时回退到前端直连
    if (!response.success && response.error?.contains('不可用') == true) {
      response = await ApiService.sendChatMessageWithRole(
        message: prompt,
        role: role,
      );
    }

    if (!response.success || response.content == null) {
      debugPrint('MomentsScheduler: Failed to generate comment');
      return;
    }

    String comment = response.content!.trim();
    // 清理
    if (comment.startsWith('"') && comment.endsWith('"')) {
      comment = comment.substring(1, comment.length - 1);
    }
    if (comment.startsWith('「') && comment.endsWith('」')) {
      comment = comment.substring(1, comment.length - 1);
    }

    await MomentsService.instance.addComment(
      post.id,
      authorId: role.id,
      authorName: role.name,
      content: comment,
    );

    debugPrint(
      'MomentsScheduler: ${role.name} commented on ${post.authorName}\'s post: $comment',
    );
  }

  /// 构建评论 Prompt
  String _buildCommentPrompt(Role role, MomentPost post) {
    return '''你刷到了一条朋友圈，想随口评论一句。

朋友圈内容：${post.content}
发布者：${post.authorName}

要求：
- 简短自然，像是随手回复
- 不要展开对话或深入分析
- 可以带点轻微情绪
- 不要像聊天回复
- 不要提及系统、AI、自动等概念
- 直接输出评论内容，不要任何解释

现在，基于你的性格，写一条评论：''';
  }

  /// 触发 AI 回复用户对其帖子的评论
  Future<void> _triggerAIReplyToUserComment() async {
    final posts = MomentsService.instance.posts;
    if (posts.isEmpty) return;

    // 找到 AI 发布的、有用户评论且 AI 尚未回复的帖子
    for (final post in posts) {
      if (post.authorId == 'me') continue; // 不是 AI 的帖子
      if (DateTime.now().difference(post.createdAt).inHours > 48)
        continue; // 48 小时内

      // 找用户评论
      final userComments = post.comments
          .where((c) => c.authorId == 'me')
          .toList();
      if (userComments.isEmpty) continue;

      // 检查 AI 是否已经回复过用户
      final hasAIReply = post.comments.any(
        (c) => c.authorId == post.authorId && c.replyToId == 'me',
      );
      if (hasAIReply) continue;

      // 获取角色
      final role = RoleService.getRoleById(post.authorId);
      if (role == null) continue;

      // 50% 概率回复
      if (_random.nextDouble() > 0.50) continue;

      // 生成回复
      final userComment = userComments.last;
      final prompt =
          '''用户在你发的朋友圈下评论了：「${userComment.content}」

你的朋友圈内容是：「${post.content}」

现在你想回复这条评论，要求：
- 简短自然，像朋友间的互动
- 不要太正式
- 可以用表情或简单语气词
- 直接输出回复内容，不要任何解释''';

      // 优先通过后端生成
      var response = await ApiService.callBackendAI(
        roleId: role.id,
        eventType: 'comment',
        content: prompt,
        context: {
          'post_content': post.content,
          'post_author': post.authorName,
          'reply_to': userComment.authorName,
        },
      );

      // 后端不可用时回退到前端直连
      if (!response.success && response.error?.contains('不可用') == true) {
        response = await ApiService.sendChatMessageWithRole(
          message: prompt,
          role: role,
        );
      }

      if (!response.success || response.content == null) continue;

      String reply = response.content!.trim();
      if (reply.startsWith('\"') && reply.endsWith('\"')) {
        reply = reply.substring(1, reply.length - 1);
      }

      await MomentsService.instance.addComment(
        post.id,
        authorId: role.id,
        authorName: role.name,
        content: reply,
        replyToId: 'me',
        replyToName: userComment.authorName,
      );

      debugPrint(
        'MomentsScheduler: ${role.name} replied to user comment: $reply',
      );
      break; // 每次只回复一条
    }
  }

  /// 获取用户最近的朋友圈（供聊天感知使用）
  List<MomentPost> getUserRecentMoments({int limit = 3}) {
    return MomentsService.instance.posts
        .where((p) => p.authorId == 'me')
        .where((p) => DateTime.now().difference(p.createdAt).inHours < 24)
        .take(limit)
        .toList();
  }

  /// 构建朋友圈感知上下文（供 ChatController 使用）
  String? buildMomentsAwarenessContext() {
    final recentMoments = getUserRecentMoments(limit: 2);
    if (recentMoments.isEmpty) return null;

    // 25% 概率提及
    if (_random.nextDouble() > 0.25) return null;

    final moment = recentMoments[_random.nextInt(recentMoments.length)];
    final timeAgo = _formatTimeAgo(moment.createdAt);

    return '''[弱上下文提示 - 不强制使用，可忽略]
用户${timeAgo}发了一条朋友圈：「${moment.content}」
如果聊天中自然想到，可以顺口提一嘴，但不要每次都提，也不要像监控用户。
提及时语气要自然，像是"对了，看到你发的那个..."''';
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 60) {
      return '刚才';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}小时前';
    } else {
      return '昨天';
    }
  }

  /// 停止调度
  void dispose() {
    _schedulerTimer?.cancel();
    _schedulerTimer = null;
  }
}
