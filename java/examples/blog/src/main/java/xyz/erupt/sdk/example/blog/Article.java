package xyz.erupt.sdk.example.blog;

import jakarta.persistence.Entity;
import jakarta.persistence.Lob;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import xyz.erupt.annotation.Erupt;
import xyz.erupt.annotation.EruptField;
import xyz.erupt.annotation.sub_erupt.RowOperation;
import xyz.erupt.annotation.sub_field.Edit;
import xyz.erupt.annotation.sub_field.EditType;
import xyz.erupt.annotation.sub_field.View;
import xyz.erupt.annotation.sub_field.sub_edit.ChoiceType;
import xyz.erupt.annotation.sub_field.sub_edit.ReferenceTreeType;
import xyz.erupt.annotation.sub_field.sub_edit.Search;
import xyz.erupt.annotation.sub_field.sub_edit.VL;
import xyz.erupt.jpa.model.BaseModel;

import java.time.LocalDate;
import java.time.LocalDateTime;

@Entity
@Table(name = "blog_article")
@Erupt(name = "Article", orderBy = "id desc", rowOperation = {
        @RowOperation(code = "publish", title = "Publish", icon = "fa fa-paper-plane", ifExpr = "item.status !== 'published'",
                eruptClass = PublishForm.class, operationHandler = ArticleOperations.Publish.class),
        @RowOperation(code = "feature", title = "Feature", mode = RowOperation.Mode.SINGLE, icon = "fa fa-star",
                callHint = "Feature this article on the home page?", operationHandler = ArticleOperations.Feature.class)
})
public class Article extends BaseModel {

    @EruptField(views = @View(title = "Title", sortable = true), edit = @Edit(title = "Title", notNull = true, search = @Search))
    private String title;

    @ManyToOne
    @EruptField(views = @View(title = "Category", column = "name"), edit = @Edit(title = "Category", search = @Search))
    private Category category;

    @ManyToOne
    @EruptField(edit = @Edit(title = "Topic", type = EditType.REFERENCE_TREE, referenceTreeType = @ReferenceTreeType(pid = "parent.id")))
    private Category topic;

    @EruptField(views = @View(title = "Status"), edit = @Edit(title = "Status", type = EditType.CHOICE, search = @Search,
            choiceType = @ChoiceType(vl = {@VL(value = "draft", label = "Draft"), @VL(value = "published", label = "Published")})))
    private String status;

    @EruptField(views = @View(title = "Views", sortable = true), edit = @Edit(title = "Views"))
    private Integer views;

    @EruptField(views = @View(title = "Featured"), edit = @Edit(title = "Featured", search = @Search))
    private Boolean featured;

    @EruptField(views = @View(title = "Publish Date"), edit = @Edit(title = "Publish Date", search = @Search))
    private LocalDate publishDate;

    @EruptField(views = @View(title = "Review At", sortable = true), edit = @Edit(title = "Review At"))
    private LocalDateTime reviewAt;

    @Lob
    @EruptField(edit = @Edit(title = "Body", type = EditType.TEXTAREA))
    private String body;

    public void setStatus(String status) {
        this.status = status;
    }

    public void setPublishDate(LocalDate publishDate) {
        this.publishDate = publishDate;
    }

    public void setFeatured(Boolean featured) {
        this.featured = featured;
    }

}
