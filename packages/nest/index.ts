import { Scope, type DynamicModule, type Provider } from "@nestjs/common";
import { DiscoveryModule, DiscoveryService } from "@nestjs/core";
import {
  createBackend,
  type BackendOptions,
  type Handler,
  type Loader,
  type ReadContext,
} from "../server/index.mts";

type Method = Function;
type HandlerDescriptor = { name: string; version: number };
const handlerMetadata = new WeakMap<Method, HandlerDescriptor>();
const loaderMetadata = new WeakMap<Method, string>();
export const LOCAL_FIRST_BACKEND = Symbol("LOCAL_FIRST_BACKEND");
const LOCAL_FIRST_OPTIONS = Symbol("LOCAL_FIRST_OPTIONS");

export type NestHandler<T, Input = Record<string, any>> = Handler<T, Input>;
export type NestLoader<T, Identity = any> = (
  context: ReadContext<T>,
  identities: readonly Identity[],
) => Promise<readonly (object | null)[]>;

export function Handles(name: string, version: number): MethodDecorator {
  return (_target, _property, descriptor) => {
    if (!descriptor?.value) throw new Error("@Handles requires a method");
    handlerMetadata.set(descriptor.value as unknown as Method, {
      name,
      version,
    });
  };
}
export function Loads(model: string): MethodDecorator {
  return (_target, _property, descriptor) => {
    if (!descriptor?.value) throw new Error("@Loads requires a method");
    loaderMetadata.set(descriptor.value as unknown as Method, model);
  };
}

function decoratedMethods(
  instance: object,
): { method: Method; bound: Method }[] {
  const found: { method: Method; bound: Method }[] = [];
  for (
    let prototype = Object.getPrototypeOf(instance);
    prototype && prototype !== Object.prototype;
    prototype = Object.getPrototypeOf(prototype)
  ) {
    for (const name of Object.getOwnPropertyNames(prototype)) {
      if (name === "constructor") continue;
      const method = Object.getOwnPropertyDescriptor(prototype, name)?.value;
      if (
        typeof method === "function" &&
        (handlerMetadata.has(method) || loaderMetadata.has(method))
      )
        found.push({ method, bound: method.bind(instance) });
    }
  }
  return found;
}

export function registrationsFromProviders<T>(instances: readonly object[]) {
  const handlers: Record<string, Record<number, Handler<T, any>>> = {};
  const loaders: Record<string, Loader<T>> = {};
  for (const instance of instances)
    for (const { method, bound } of decoratedMethods(instance)) {
      const handler = handlerMetadata.get(method);
      if (handler) {
        if (handlers[handler.name]?.[handler.version])
          throw new Error(
            `Duplicate handler ${handler.name} v${handler.version}`,
          );
        (handlers[handler.name] ??= {})[handler.version] = bound as Handler<
          T,
          any
        >;
      }
      const model = loaderMetadata.get(method);
      if (model) {
        if (loaders[model]) throw new Error(`Duplicate loader ${model}`);
        const prepare = (instance as any).prepareForViewer;
        loaders[model] = {
          load: bound as NestLoader<T>,
          ...(typeof prepare === "function"
            ? { prepareForViewer: prepare.bind(instance) }
            : {}),
        };
      }
    }
  return { handlers, loaders };
}

type NestOptions<T> = Omit<BackendOptions<T>, "handlers" | "loaders">;
export class LocalFirstModule {
  static register<T>(options: NestOptions<T>): DynamicModule {
    const backend: Provider = {
      provide: LOCAL_FIRST_BACKEND,
      inject: [DiscoveryService, LOCAL_FIRST_OPTIONS],
      useFactory: (discovery: DiscoveryService, value: NestOptions<T>) => {
        let ready: ReturnType<typeof createBackend<T>> | undefined;
        const deferred = {
          onModuleInit() {
            const instances: object[] = [];
            for (const wrapper of discovery.getProviders()) {
              const instance = wrapper.instance;
              if (
                instance == null ||
                typeof instance !== "object" ||
                decoratedMethods(instance).length === 0
              )
                continue;
              if (
                (wrapper.scope !== undefined &&
                  wrapper.scope !== Scope.DEFAULT) ||
                !wrapper.isDependencyTreeStatic()
              )
                throw new Error(
                  "Decorated backend providers must be singleton providers",
                );
              instances.push(instance);
            }
            ready = createBackend({
              ...value,
              ...registrationsFromProviders<T>(instances),
            });
          },
        };
        const names = [
          "push",
          "pull",
          "negotiateLive",
          "pullLive",
          "onCommitted",
          "notifyCommitted",
          "closeLive",
          "publish",
          "bindTransaction",
        ] as const;
        return Object.assign(
          deferred,
          Object.fromEntries(
            names.map((name) => [
              name,
              (...args: unknown[]) => {
                if (!ready)
                  throw new Error(
                    "Backend is not ready until Nest initialization completes",
                  );
                return (ready[name] as Function)(...args);
              },
            ]),
          ),
        );
      },
    };
    return {
      module: LocalFirstModule,
      imports: [DiscoveryModule],
      providers: [{ provide: LOCAL_FIRST_OPTIONS, useValue: options }, backend],
      exports: [backend],
    };
  }
}
