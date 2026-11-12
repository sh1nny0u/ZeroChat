"""
网络搜索服务
使用 DuckDuckGo 实现免 API Key 的网络搜索
"""
from typing import Optional, List, Dict
from services.logging_service import get_logger

logger = get_logger("chat")


def should_search(message: str) -> bool:
    """
    判断用户消息是否需要联网搜索
    基于关键词和模式匹配
    """
    # 搜索触发关键词
    search_triggers = [
        # 直接搜索意图
        "搜索", "查一下", "查询", "帮我查", "百度", "谷歌", "google", "搜一下",
        # 时效性
        "最新", "新闻", "今天", "昨天", "现在", "目前", "最近", "刚刚", "发生了什么",
        # 知识性问题
        "什么是", "是什么", "怎么样", "如何", "怎样", "了解",
        # 价格/数据
        "天气", "股票", "价格", "多少钱", "汇率",
        # 人/地点
        "谁是", "哪个", "哪里", "在哪",
        # 影视/娱乐/文化
        "电影", "电视剧", "综艺", "动漫", "番剧", "歌曲", "专辑",
        "上映", "播出", "首播", "票房", "评分", "豆瓣",
        "看过", "听过", "推荐",
        # 科技/产品
        "发布", "上市", "更新", "版本", "配置", "参数",
        # 体育
        "比赛", "赛事", "比分", "冠军",
        # 英文
        "search", "look up", "find", "latest", "newest", "recent",
    ]
    
    msg_lower = message.lower()
    for trigger in search_triggers:
        if trigger in msg_lower:
            logger.info("", extra={"event": "search_selected"})
            return True
    
    # 问号结尾且包含实体性词汇也可能需要搜索
    if message.strip().endswith("？") or message.strip().endswith("?"):
        entity_hints = ["谁", "什么", "哪", "几", "多少", "怎么", "为什么", "如何", "有没有", "是不是"]
        for hint in entity_hints:
            if hint in message:
                logger.info("", extra={"event": "search_selected"})
                return True
    
    logger.debug("", extra={"event": "search_skipped"})
    return False


async def web_search(query: str, max_results: int = 5) -> List[Dict[str, str]]:
    """
    执行网络搜索
    
    Returns:
        [{"title": "...", "body": "...", "href": "..."}]
    """
    try:
        from duckduckgo_search import DDGS
        
        logger.info("", extra={"event": "search_started"})
        
        results = []
        with DDGS(timeout=10) as ddgs:
            for r in ddgs.text(query, max_results=max_results):
                results.append({
                    "title": r.get("title", ""),
                    "body": r.get("body", ""),
                    "href": r.get("href", ""),
                })
        
        logger.info("", extra={"event": "search_completed", "count": len(results)})
        return results
        
    except ImportError:
        logger.warning("", extra={"event": "search_dependency_missing", "error_type": "ImportError"})
        return []
    except Exception:
        logger.exception("", extra={"event": "search_failed"})
        return []


def format_search_results(results: List[Dict[str, str]]) -> str:
    """
    将搜索结果格式化为可注入 AI 上下文的文本
    """
    if not results:
        return ""
    
    lines = ["[联网搜索结果]"]
    for i, r in enumerate(results, 1):
        title = r.get("title", "")
        body = r.get("body", "")
        lines.append(f"{i}. {title}")
        if body:
            lines.append(f"   {body}")
    
    lines.append("")
    lines.append("请根据以上搜索结果，结合你的角色人设自然地回答用户的问题。不要直接罗列搜索结果，而是消化后用自己的话回答。")
    
    return "\n".join(lines)
