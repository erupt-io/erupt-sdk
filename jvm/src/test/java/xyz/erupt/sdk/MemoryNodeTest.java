package xyz.erupt.sdk;

import xyz.erupt.sdk.Models.Article;

class MemoryNodeTest extends NodeTest {

    @Override
    Repository<Article> articles() {
        return new MemoryRepository<>();
    }
}
