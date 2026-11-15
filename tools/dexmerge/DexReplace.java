import com.android.tools.smali.dexlib2.DexFileFactory;
import com.android.tools.smali.dexlib2.HiddenApiRestriction;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.DexFile;
import com.android.tools.smali.dexlib2.iface.Field;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.immutable.ImmutableClassDef;
import com.android.tools.smali.dexlib2.immutable.ImmutableField;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethod;
import com.android.tools.smali.dexlib2.util.MethodUtil;
import com.android.tools.smali.dexlib2.writer.io.FileDataStore;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Writes a copy of a dex with some classes replaced by the same-named classes
 * from another dex. Used by tools/patch_framework.sh: older smali cannot
 * assemble every class of an Android 16 framework dex, so only the classes a
 * patch changed are reassembled, and dexlib2 3.x writes the rest as they are.
 *
 * The replacement classes are assembled without hidden-API flags (smali 2.5
 * does not know the newer ones), so each member gets the flags of the
 * same-named member in the original class; members the patch added get none.
 *
 *   java DexReplace <api> <in.dex> <replacements.dex> <out.dex>
 *
 * Every class of replacements.dex must already exist in in.dex.
 */
public final class DexReplace {
    private static String key(Method m) {
        return m.getName() + MethodUtil.getShorty(m.getParameters(), m.getReturnType())
                + m.getParameterTypes() + m.getReturnType();
    }

    private static ClassDef withFlags(ClassDef orig, ClassDef repl) {
        Map<String, Set<HiddenApiRestriction>> mflags = new HashMap<>();
        for (Method m : orig.getMethods()) mflags.put(key(m), m.getHiddenApiRestrictions());
        Map<String, Set<HiddenApiRestriction>> fflags = new HashMap<>();
        for (Field f : orig.getFields()) fflags.put(f.getName() + ":" + f.getType(), f.getHiddenApiRestrictions());

        List<ImmutableMethod> methods = new ArrayList<>();
        for (Method m : repl.getMethods()) {
            Set<HiddenApiRestriction> h = mflags.getOrDefault(key(m), Collections.emptySet());
            methods.add(new ImmutableMethod(m.getDefiningClass(), m.getName(), m.getParameters(),
                    m.getReturnType(), m.getAccessFlags(), m.getAnnotations(), h, m.getImplementation()));
        }
        List<ImmutableField> fields = new ArrayList<>();
        for (Field f : repl.getFields()) {
            Set<HiddenApiRestriction> h = fflags.getOrDefault(f.getName() + ":" + f.getType(), Collections.emptySet());
            fields.add(new ImmutableField(f.getDefiningClass(), f.getName(), f.getType(), f.getAccessFlags(),
                    f.getInitialValue(), f.getAnnotations(), h));
        }
        return new ImmutableClassDef(repl.getType(), repl.getAccessFlags(), repl.getSuperclass(),
                repl.getInterfaces(), repl.getSourceFile(), repl.getAnnotations(), fields, methods);
    }

    public static void main(String[] args) throws Exception {
        // args[0] (the API level) is kept for the command line; the opcodes
        // come from the input dex's own header version, which dexlib2 3.0.x
        // knows even where it has no mapping for the newest API levels.
        DexFile in = DexFileFactory.loadDexFile(new File(args[1]), null);
        Opcodes opcodes = in.getOpcodes();
        DexFile repl = DexFileFactory.loadDexFile(new File(args[2]), opcodes);

        Map<String, ClassDef> byType = new HashMap<>();
        for (ClassDef c : repl.getClasses()) byType.put(c.getType(), c);

        Set<String> seen = new HashSet<>();
        DexPool pool = new DexPool(opcodes);
        int total = 0;
        for (ClassDef c : in.getClasses()) {
            ClassDef r = byType.get(c.getType());
            if (r != null) seen.add(c.getType());
            pool.internClass(r != null ? withFlags(c, r) : c);
            total++;
        }
        for (String t : byType.keySet()) {
            if (!seen.contains(t)) throw new IllegalStateException(t + " is not in " + args[1]);
        }
        pool.writeTo(new FileDataStore(new File(args[3])));
        System.err.println("DexReplace: " + total + " classes written, " + seen.size() + " replaced");
    }
}
