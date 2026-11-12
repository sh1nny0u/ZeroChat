import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/resource_cache_service.dart';

class ResourceImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  const ResourceImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (!ResourceCacheService.accessAllowed) {
      return SizedBox(width: width, height: height, child: const Icon(Icons.lock_outline));
    }
    final isNetwork =
        url.startsWith('http://') ||
        url.startsWith('https://') ||
        url.startsWith('/api/');
    if (!isNetwork) {
      return Image.file(
        File(url),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: errorBuilder,
      );
    }
    return CachedNetworkImage(
      key: ValueKey(ResourceCacheService.key(url)),
      imageUrl: ResourceCacheService.resolve(url),
      cacheKey: ResourceCacheService.key(url),
      cacheManager: ResourceCacheService.manager,
      httpHeaders: ResourceCacheService.headersFor(url),
      width: width,
      height: height,
      fit: fit,
      fadeInDuration: Duration.zero,
      errorWidget: (context, url, error) =>
          errorBuilder?.call(context, error, null) ??
          const Icon(Icons.broken_image_outlined),
    );
  }
}
