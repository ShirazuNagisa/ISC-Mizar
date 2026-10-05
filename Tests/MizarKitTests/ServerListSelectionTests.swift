import Testing
import MizarApp

/// 服务端列表的导航选中项。
///
/// # 这一套钉住的是"从详情返回列表之后，那一行再也点不进去"
///
/// iPhone 上（紧凑宽度）系统会把 `List(selection:)` 的选中项写成 `nil`
/// —— 那是"回到列表"，也是它为自己做的**导航复位**。原来的绑定把 `nil`
/// 吞掉了（`if let id = $0`），于是系统那一侧永远回不到"可以再选一次"：
/// 再点同一行时选中项从 A 变成 A，没有任何变化，也就没有任何导航。
///
/// 这套断言刻意都在**值**这一层，因为"点不进去"的成因就在值这一层。
@Suite("ServerListSelection")
struct ServerListSelectionTests {

    /// 系统写回来的 `nil` 必须被**存下来**，而不是被吞掉。
    @Test func aNilWriteIsStoredNotSwallowed() {
        var selection = ServerListSelection(highlighted: "srv-1")

        #expect(selection.apply(nil) == nil, "nil 不代表要打开任何一台服务端")
        #expect(selection.value == nil,
                "但系统写进来的 nil 必须原样存下来 —— 吞掉它，系统的导航复位就永远做不成")
    }

    /// 返回列表之后再点同一行，值必须**变**（nil → A）。
    ///
    /// 导航是由"选中项变了"驱动的。值不变就没有导航 —— 这正是
    /// "列表点了没反应"。
    @Test func reselectingTheSameServerChangesTheValueAgain() {
        var selection = ServerListSelection(highlighted: "srv-1")

        _ = selection.apply(nil)                    // 用户从详情返回列表
        #expect(selection.apply("srv-1") == "srv-1", "这一声要交给 AppModel.select")
        #expect(selection.value == "srv-1", "值必须真的变过，否则列表不会推详情")
    }

    /// 模型换了"正在看哪一台"，高亮跟过去（配对、通知深链、删掉当前这台）。
    @Test func theHighlightFollowsTheModel() {
        var selection = ServerListSelection(highlighted: "srv-1")

        selection.syncFromModel("srv-2")
        #expect(selection.value == "srv-2", "模型换了服务器，列表的高亮不能还停在上一台")
    }

    /// 用户返回列表（高亮变 nil）之后，同步逻辑不能把高亮又拉回来。
    ///
    /// 拉回来就等于把列表重新画成"已经进入过"的样子，而系统的导航复位
    /// 是它自己做的 —— 两边一拉一拽，那一行又会点不进去。
    @Test func goingBackToListIsNotUndoneByASync() {
        var selection = ServerListSelection(highlighted: "srv-1")

        _ = selection.apply(nil)
        selection.syncFromModel("srv-1")            // 模型并没有变

        #expect(selection.value == nil,
                "模型没变就不该把高亮拉回来 —— 那会让那一行又变成「已经进入过」")
    }
}
